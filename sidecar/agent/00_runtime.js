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
let mainThreadWakeMessage = 0;
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

/** Agent内の診断メッセージをNodeヘルパーへ送ります。 */
function emitLog(message) {
  send({ type: 'log', message: String(message) });
}

/** 解析マニフェストのRVAを、対象モジュールの実アドレスへ変換します。 */
function rva(value) {
  return targetModule.base.add(parseInteger(value));
}

/** 10進数または0x付き16進数のマニフェスト値を整数へ変換します。 */
function parseInteger(value) {
  if (typeof value === 'number') return value;
  const text = String(value || '0');
  return text.startsWith('0x') ? parseInt(text.substring(2), 16) : parseInt(text, 10);
}

/** 空白を許した16進命令列を、検証済みバイト配列へ変換します。 */
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

/** 対象プロセスの指定アドレスから固定長バイト列を読み取ります。 */
function readBytes(address, length) {
  return Array.from(new Uint8Array(address.readByteArray(length)));
}

/** 2つのバイト配列が長さを含め完全一致するか判定します。 */
function sameBytes(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

/** 診断表示用に、バイト配列を小文字16進文字列へ変換します。 */
function bytesText(value) {
  return value.map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

/** フック先関数の先頭命令列をマニフェストと照合し、不一致なら接続を拒否します。 */
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

/** DAMメインスレッド待機用の一時Interceptorをすべて解除します。 */
function detachMainThreadListener() {
  while (mainThreadListeners.length > 0) {
    const listener = mainThreadListeners.pop();
    try {
      listener.detach();
    } catch (_) {
      // スクリプト破棄やDAM終了後は待機中リスナー自体が無効なため、解放を続けます。
    }
  }
}

/** 所有者のない可視トップレベルウィンドウから、DAMのウィンドウとUIスレッドを取得します。 */
function damMainWindow() {
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
  let result = null;
  // DAMプロセスに属する最初の主要ウィンドウを列挙するコールバックです。
  const callback = new NativeCallback(
    (window) => {
      processId.writeU32(0);
      const candidate = getWindowThreadProcessId(window, processId);
      if (processId.readU32() !== Process.id || isWindowVisible(window) === 0) {
        return 1;
      }
      // GW_OWNER=4で所有者を確認し、DAM自身のトップレベルウィンドウを優先します。
      if (!getWindow(window, 4).isNull()) return 1;
      result = { window, threadId: candidate };
      return 0;
    },
    'int',
    ['pointer', 'pointer'],
  );
  enumWindows(callback, NULL);
  return result;
}

/** UIスレッドへ到達した保留タスクを順に実行し、次の待機を再設定します。 */
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

/** このアプリ専用のWindowsメッセージ番号を登録し、他のメッセージと衝突しないようにします。 */
function registeredMainThreadWakeMessage(user32) {
  if (mainThreadWakeMessage !== 0) return mainThreadWakeMessage;
  const registerWindowMessage = new NativeFunction(
    user32.getExportByName('RegisterWindowMessageW'),
    'uint',
    ['pointer'],
  );
  const name = Memory.allocUtf16String(
    `DAMforWindowsTools.MainThread.${Process.id}`,
  );
  mainThreadWakeMessage = registerWindowMessage(name);
  if (mainThreadWakeMessage === 0) {
    throw new Error('DAMメインスレッド用メッセージを登録できませんでした');
  }
  return mainThreadWakeMessage;
}

/** DAMのWndProcが専用メッセージを処理し終えた直後に、保留タスクを実行します。 */
function armMainThreadDispatcher() {
  if (mainThreadListeners.length > 0 || mainThreadTasks.length === 0) return;
  const mainWindow = damMainWindow();
  if (mainWindow === null) return;
  const user32 = Process.getModuleByName('user32.dll');
  const wakeMessage = registeredMainThreadWakeMessage(user32);
  mainThreadListeners.push(
    Interceptor.attach(user32.getExportByName('DispatchMessageW'), {
      // x64のMSGは先頭がHWND、+8がmessageです。専用メッセージだけを識別します。
      onEnter(args) {
        this.isDamWakeMessage = false;
        if (Process.getCurrentThreadId() !== mainWindow.threadId || args[0].isNull()) {
          return;
        }
        const message = args[0];
        this.isDamWakeMessage =
          message.readPointer().equals(mainWindow.window) &&
          message.add(Process.pointerSize).readU32() === wakeMessage;
      },
      // WndProc内の処理が完了してから実行し、メッセージ取得中の再入を防ぎます。
      onLeave() {
        if (this.isDamWakeMessage && mainThreadTasks.length > 0) {
          drainMainThreadTasks();
        }
      },
    }),
  );
  const postMessage = new NativeFunction(
    user32.getExportByName('PostMessageW'),
    'int',
    ['pointer', 'uint', 'pointer', 'pointer'],
  );
  if (postMessage(mainWindow.window, wakeMessage, NULL, NULL) === 0) {
    detachMainThreadListener();
    throw new Error('DAMメインウィンドウへ処理要求を送信できませんでした');
  }
}

/** DAM内部操作をUIスレッドへ移し、期限内に実行できなければ拒否します。 */
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
    try {
      armMainThreadDispatcher();
    } catch (error) {
      task.active = false;
      clearTimeout(task.timer);
      const index = mainThreadTasks.indexOf(task);
      if (index >= 0) mainThreadTasks.splice(index, 1);
      reject(error);
    }
  });
}

/** 終了時にUIスレッド待機を解除し、全タスクを明示的なエラーで完了します。 */
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

/** 期待命令列を確認して既知の最小パッチだけを適用・復元します。 */
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

/** Flutterから受け取った機能設定をBoolean初期値へ正規化します。 */
function normalizeConfig(next) {
  const source = next && typeof next === 'object' ? next : {};
  return {
    disableModuleCheck: source.disableModuleCheck !== false,
    disableForegroundCheck: source.disableForegroundCheck !== false,
    replaceVideoUrls: source.replaceVideoUrls !== false,
    scoringEnabled: source.scoringEnabled !== false,
  };
}

/** 設定変更を既知パッチと採点セッションへ反映します。 */
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

/**
 * このAgent自身が適用した既知バイトだけを原本へ戻します。
 * 第三者変更が見つかったアドレスは上書きせず、診断イベントを返します。
 */
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
      // DAM終了中はモジュール自体が無効になり得るため、残りの復元処理を続けます。
    }
  }
  Interceptor.flush();
  patchState.clear();
}
