// Project: DAM for Windows Tools
// File: agent/00_runtime.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

'use strict';

const targetModule = Process.getModuleByName(DAM_TARGET_MANIFEST.target.processName);
const patchState = new Map();
const retainedStrings = [];
const retainedNativeCallbacks = [];
let requestSequence = 0;
let initialized = false;
let hooksInstalled = false;
let scoringSessionActive = false;
let lastOrnamentTimestamp = -1;
let pendingRemoteSearch = null;
let pendingRemoteDetail = null;
let pendingRemoteReservation = null;
let pendingRemoteFavorite = null;
const mainThreadListeners = [];
const mainThreadTasks = [];
let currentVideoId = '';
const remoteSearchRows = new Map();
let config = {
  disableModuleCheck: true,
  disableForegroundCheck: true,
  replaceVideoUrls: true,
  scoringEnabled: true,
};

const LOCAL_PREFIX = `${DAM_RUNTIME_CONFIG.mediaOrigin}/v1/`;
const LOCAL_SERVER = new RegExp(
  `^${DAM_RUNTIME_CONFIG.mediaOrigin.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?:/|$)`,
  'i',
);

function emitLog(message) {
  send({ type: 'log', message: String(message) });
}

function rva(value) {
  return targetModule.base.add(parseInteger(value));
}

function parseInteger(value) {
  if (typeof value === 'number') return value;
  const text = String(value || '0');
  return text.startsWith('0x') ? parseInt(text.substring(2), 16) : parseInt(text, 10);
}

function hexBytes(value) {
  const text = String(value).replace(/\s+/g, '').toLowerCase();
  if (text.length % 2 !== 0 || !/^[0-9a-f]*$/.test(text)) {
    throw new Error(`invalid manifest bytes: ${value}`);
  }
  const output = [];
  for (let index = 0; index < text.length; index += 2) {
    output.push(parseInt(text.substring(index, index + 2), 16));
  }
  return output;
}

function readBytes(address, length) {
  return Array.from(new Uint8Array(address.readByteArray(length)));
}

function sameBytes(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function bytesText(value) {
  return value.map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

function verifyPrefix(name, descriptor) {
  const expected = hexBytes(descriptor.expectedPrefix);
  const actual = readBytes(rva(descriptor.rva), expected.length);
  if (!sameBytes(actual, expected)) {
    const message = `${name} の命令列が解析マニフェストと一致しません ` +
      `(expected=${bytesText(expected)}, actual=${bytesText(actual)})`;
    send({ type: 'patch-error', message });
    throw new Error(message);
  }
}

function detachMainThreadListener() {
  while (mainThreadListeners.length > 0) {
    const listener = mainThreadListeners.pop();
    try {
      listener.detach();
    } catch (_) {
      // Script or process teardown can invalidate an armed listener.
    }
  }
}

function damUiThreadId() {
  const user32 = Process.getModuleByName('user32.dll');
  const enumWindows = new NativeFunction(
    user32.getExportByName('EnumWindows'),
    'int',
    ['pointer', 'pointer'],
  );
  const getWindowThreadProcessId = new NativeFunction(
    user32.getExportByName('GetWindowThreadProcessId'),
    'uint',
    ['pointer', 'pointer'],
  );
  const isWindowVisible = new NativeFunction(
    user32.getExportByName('IsWindowVisible'),
    'int',
    ['pointer'],
  );
  const getWindow = new NativeFunction(
    user32.getExportByName('GetWindow'),
    'pointer',
    ['pointer', 'uint'],
  );
  const processId = Memory.alloc(4);
  let threadId = 0;
  const callback = new NativeCallback(
    (window) => {
      processId.writeU32(0);
      const candidate = getWindowThreadProcessId(window, processId);
      if (processId.readU32() !== Process.id || isWindowVisible(window) === 0) {
        return 1;
      }
      // GW_OWNER = 4. Prefer DAM's unowned top-level application window.
      if (!getWindow(window, 4).isNull()) return 1;
      threadId = candidate;
      return 0;
    },
    'int',
    ['pointer', 'pointer'],
  );
  enumWindows(callback, NULL);
  return threadId;
}

function drainMainThreadTasks() {
  detachMainThreadListener();
  const tasks = mainThreadTasks.splice(0, mainThreadTasks.length);
  for (const task of tasks) {
    if (!task.active) continue;
    task.active = false;
    clearTimeout(task.timer);
    try {
      task.resolve(task.run());
    } catch (error) {
      task.reject(error);
    }
  }
  armMainThreadDispatcher();
}

function armMainThreadDispatcher() {
  if (mainThreadListeners.length > 0 || mainThreadTasks.length === 0) return;
  const threadId = damUiThreadId();
  if (threadId === 0) return;
  const user32 = Process.getModuleByName('user32.dll');
  const onMessageLoop = function () {
    if (Process.getCurrentThreadId() !== threadId || mainThreadTasks.length === 0) {
      return;
    }
    drainMainThreadTasks();
  };
  for (const api of ['PeekMessageW', 'GetMessageW']) {
    mainThreadListeners.push(
      Interceptor.attach(user32.getExportByName(api), { onEnter: onMessageLoop }),
    );
  }
  const postThreadMessage = new NativeFunction(
    user32.getExportByName('PostThreadMessageW'),
    'int',
    ['uint', 'uint', 'pointer', 'pointer'],
  );
  // WM_NULL wakes the existing loop without creating any visible UI action.
  postThreadMessage(threadId, 0, NULL, NULL);
}

function runOnDamMainThread(name, run, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const task = {
      active: true,
      name,
      run,
      resolve,
      reject,
      timer: null,
    };
    task.timer = setTimeout(() => {
      if (!task.active) return;
      task.active = false;
      const index = mainThreadTasks.indexOf(task);
      if (index >= 0) mainThreadTasks.splice(index, 1);
      if (mainThreadTasks.length === 0) detachMainThreadListener();
      reject(new Error(`${name} をDAMのメインスレッドで実行できませんでした`));
    }, timeoutMs);
    mainThreadTasks.push(task);
    armMainThreadDispatcher();
  });
}

function cancelMainThreadTasks() {
  detachMainThreadListener();
  const tasks = mainThreadTasks.splice(0, mainThreadTasks.length);
  for (const task of tasks) {
    if (!task.active) continue;
    task.active = false;
    clearTimeout(task.timer);
    task.reject(
      new Error('DAM for Windows Toolsの終了によりDAM操作を中止しました'),
    );
  }
}

function setPatch(name, descriptor, enabled) {
  const address = rva(descriptor.rva);
  const expected = hexBytes(descriptor.expected);
  const patched = hexBytes(descriptor.patched);
  const actual = readBytes(address, expected.length);
  const expectedCurrent = enabled ? expected : patched;
  const desired = enabled ? patched : expected;
  if (sameBytes(actual, desired)) {
    patchState.set(name, enabled);
    return;
  }
  if (!sameBytes(actual, expectedCurrent)) {
    const message = `${name} の変更を拒否しました ` +
      `(expected=${bytesText(expectedCurrent)}, actual=${bytesText(actual)})`;
    send({ type: 'patch-error', message });
    throw new Error(message);
  }
  Memory.protect(address, desired.length, 'rwx');
  address.writeByteArray(desired);
  Interceptor.flush();
  patchState.set(name, enabled);
}

function normalizeConfig(next) {
  const source = next && typeof next === 'object' ? next : {};
  return {
    disableModuleCheck: source.disableModuleCheck !== false,
    disableForegroundCheck: source.disableForegroundCheck !== false,
    replaceVideoUrls: source.replaceVideoUrls !== false,
    scoringEnabled: source.scoringEnabled !== false,
  };
}

function applyConfig(next) {
  const wasScoringEnabled = config.scoringEnabled;
  config = normalizeConfig(next);
  setPatch('moduleCheck', DAM_TARGET_MANIFEST.patches.moduleCheck, config.disableModuleCheck);
  setPatch(
    'foregroundLost',
    DAM_TARGET_MANIFEST.patches.foregroundLost,
    config.disableForegroundCheck,
  );
  setPatch(
    'foregroundTransition',
    DAM_TARGET_MANIFEST.patches.foregroundTransition,
    config.disableForegroundCheck,
  );
  if (wasScoringEnabled && !config.scoringEnabled) {
    finishScoringSession();
  }
  if (!wasScoringEnabled && config.scoringEnabled) {
    lastOrnamentTimestamp = -1;
  }
  emitLog(
    `機能更新: module=${config.disableModuleCheck}, ` +
      `foreground=${config.disableForegroundCheck}, video=${config.replaceVideoUrls}, ` +
      `scoring=${config.scoringEnabled}`,
  );
}

function restorePatches() {
  for (const [name, descriptor] of Object.entries(DAM_TARGET_MANIFEST.patches)) {
    try {
      const address = rva(descriptor.rva);
      const expected = hexBytes(descriptor.expected);
      const patched = hexBytes(descriptor.patched);
      const actual = readBytes(address, expected.length);
      if (sameBytes(actual, patched)) {
        Memory.protect(address, expected.length, 'rwx');
        address.writeByteArray(expected);
      } else if (!sameBytes(actual, expected)) {
        send({
          type: 'patch-error',
          message: `${name} は第三者によって変更されているため復元しません`,
        });
      }
    } catch (_) {
      // Process teardown can invalidate the module while unloading.
    }
  }
  Interceptor.flush();
  patchState.clear();
}
