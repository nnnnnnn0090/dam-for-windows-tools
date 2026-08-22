// Project: DAM for Windows Tools
// File: agent.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

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

function safeUtf8(pointer, maximum = 8192) {
  if (!pointer || pointer.isNull()) return '';
  try {
    const value = pointer.readUtf8String(maximum) || '';
    const zero = value.indexOf('\u0000');
    return (zero >= 0 ? value.substring(0, zero) : value).trim();
  } catch (_) {
    try {
      return (pointer.readUtf8String() || '').trim();
    } catch (_) {
      return '';
    }
  }
}

function safeUtf16(pointer, maximum = 8192) {
  if (!pointer || pointer.isNull()) return '';
  try {
    const value = pointer.readUtf16String(maximum) || '';
    const zero = value.indexOf('\u0000');
    return (zero >= 0 ? value.substring(0, zero) : value).trim();
  } catch (_) {
    try {
      return (pointer.readUtf16String() || '').trim();
    } catch (_) {
      return '';
    }
  }
}

function cleanId(value) {
  const text = String(value == null ? '' : value).trim();
  return text.length <= 128 && /^[0-9A-Za-z]+-[0-9A-Za-z_-]+$/.test(text)
    ? text
    : '';
}

function cleanText(value) {
  if (typeof value !== 'string') return '';
  const cleaned = value
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return cleaned.length <= 300 ? cleaned : '';
}

function safeCString(pointer, maximum) {
  if (!pointer || pointer.isNull()) return '';
  try {
    const value = pointer.readUtf8String();
    return typeof value === 'string' ? value.slice(0, maximum) : '';
  } catch (_) {
    return '';
  }
}

function cleanCorrelationId(value) {
  const text = String(value == null ? '' : value);
  return /^[0-9A-Za-z_-]{8,128}$/.test(text) ? text : '';
}

function cleanSearchQuery(value, capacity) {
  if (typeof value !== 'string') return '';
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
  return cleaned.length > 0 && cleaned.length < capacity ? cleaned : '';
}

function validRemoteUrl(value) {
  return /^https?:\/\//i.test(value) && !LOCAL_SERVER.test(value) && value.length <= 8192;
}

function descriptorFrom(values) {
  return {
    videoId: cleanId(values.videoId),
    highUrl: validRemoteUrl(values.highUrl || '') ? values.highUrl : '',
    lowUrl: validRemoteUrl(values.lowUrl || '') ? values.lowUrl : '',
  };
}

function resolveDescriptor(highUrl, lowUrl) {
  return descriptorFrom({
    videoId: extractVideoAssetId(highUrl) || extractVideoAssetId(lowUrl),
    highUrl,
    lowUrl,
  });
}

function emitCurrentPlaybackMetadata(descriptor) {
  const metadata = DAM_TARGET_MANIFEST.hooks.currentPlaybackMetadata;
  try {
    if (rva(metadata.currentVideoIdRva).readU8() === 0) return;
    const maximum = parseInteger(metadata.capacityChars);
    const artist = cleanText(safeUtf16(rva(metadata.artistRva), maximum));
    const title = cleanText(safeUtf16(rva(metadata.titleRva), maximum));
    if (!artist && !title) return;
    if (!descriptor.videoId) return;
    send({
      type: 'metadata',
      candidates: [{ ids: [descriptor.videoId], artist, title }],
    });
  } catch (_) {
    // Playback must continue unchanged when read-only metadata is unavailable.
  }
}

function currentGlobalScoring() {
  const descriptor = DAM_TARGET_MANIFEST.hooks.globalScoring;
  const value = rva(descriptor.valueRva).readU32();
  if (value !== descriptor.disabledValue && value !== descriptor.enabledValue) {
    throw new Error(`DAMの採点設定値が不正です: ${value}`);
  }
  return value === descriptor.enabledValue;
}

function setGlobalScoring(enabled) {
  const descriptor = DAM_TARGET_MANIFEST.hooks.globalScoring;
  // The home handler at 0x1381CC writes this exact 0/1 value. DAM's main loop
  // observes it and applies the same setting to the scoring controller.
  currentGlobalScoring();
  rva(descriptor.valueRva).writeU32(
    enabled ? descriptor.enabledValue : descriptor.disabledValue,
  );
}

function currentRemoteState() {
  const playback = DAM_TARGET_MANIFEST.hooks.remotePlaybackControl;
  const metadata = DAM_TARGET_MANIFEST.hooks.currentPlaybackMetadata;
  let playing = false;
  let paused = false;
  let key = 0;
  let artist = '';
  let title = '';
  let videoId = '';
  let damScoring = false;
  try {
    videoId = cleanId(safeCString(rva(metadata.currentVideoIdRva), 64));
    const playbackMode = rva(playback.modeRva).readU32();
    playing = videoId.length > 0 && (playbackMode === 0 || playbackMode === 1);
    paused = playing && rva(playback.pausedRva).readU8() !== 0;
    key = rva(playback.keyRva).readS32();
    damScoring = currentGlobalScoring();
    if (playing) {
      const capacity = parseInteger(metadata.capacityChars);
      artist = cleanText(safeUtf16(rva(metadata.artistRva), capacity));
      title = cleanText(safeUtf16(rva(metadata.titleRva), capacity));
    }
  } catch (_) {
    playing = false;
    paused = false;
    key = 0;
    artist = '';
    title = '';
    videoId = '';
    damScoring = false;
  }
  return {
    connected: initialized,
    playing,
    paused,
    key: Math.max(
      parseInteger(playback.minimumKey),
      Math.min(parseInteger(playback.maximumKey), key),
    ),
    videoId: playing ? (currentVideoId || videoId) : '',
    artist,
    title,
    damScoring,
  };
}

function readQueueRecord(address, cutIn, index) {
  const descriptor = DAM_TARGET_MANIFEST.hooks.remoteRequestQueue;
  const queueId = address.add(parseInteger(descriptor.queueIdOffset)).readU32();
  if (queueId === 0) return null;
  const capacity = parseInteger(descriptor.textCapacityChars);
  const title = cleanText(
    safeUtf16(address.add(parseInteger(descriptor.titleOffset)), capacity),
  );
  const artist = cleanText(
    safeUtf16(address.add(parseInteger(descriptor.artistOffset)), capacity),
  );
  return {
    token: `q_${cutIn ? 'c' : 'n'}_${queueId}`,
    queueId,
    index,
    cutIn,
    artist,
    title,
  };
}

function currentRemoteQueue() {
  const descriptor = DAM_TARGET_MANIFEST.hooks.remoteRequestQueue;
  const rows = [];
  try {
    if (rva(descriptor.cutInPresentRva).readU8() !== 0) {
      const row = readQueueRecord(rva(descriptor.cutInBaseRva), true, 0);
      if (row) rows.push(row);
    }
    const count = Math.min(
      rva(descriptor.normalCountRva).readU32(),
      parseInteger(descriptor.maximumNormalEntries),
    );
    const stride = parseInteger(descriptor.recordStride);
    const base = rva(descriptor.normalBaseRva);
    for (let index = 0; index < count; index += 1) {
      const row = readQueueRecord(base.add(index * stride), false, index);
      if (row) rows.push(row);
    }
  } catch (_) {
    return [];
  }
  return rows;
}

function queueRowForToken(token) {
  const normalized = String(token == null ? '' : token);
  return currentRemoteQueue().find((row) => row.token === normalized) || null;
}

function performRemoteControl(action) {
  const descriptor = DAM_TARGET_MANIFEST.hooks.remotePlaybackControl;
  const state = currentRemoteState();
  if (action === 'scoringOn' || action === 'scoringOff') {
    setGlobalScoring(action === 'scoringOn');
    return currentRemoteState();
  }
  if (!state.playing) throw new Error('再生中の曲がありません');
  if (action === 'pause' || action === 'resume') {
    const requestedPause = action === 'pause';
    if (state.paused !== requestedPause) {
      const setPause = new NativeFunction(
        rva(descriptor.pauseRva),
        'void',
        ['uchar', 'char'],
      );
      setPause(requestedPause ? 1 : 0, 0);
    }
  } else if (action === 'stop') {
    const stop = new NativeFunction(rva(descriptor.stopRva), 'void', []);
    stop();
  } else if (action === 'restart') {
    const restart = new NativeFunction(rva(descriptor.restartRva), 'void', []);
    restart();
  } else if (action === 'keyDown' || action === 'keyUp' || action === 'keyReset') {
    const direction = action === 'keyDown' ? -1 : action === 'keyUp' ? 1 : 0;
    const next = action === 'keyReset'
      ? 0
      : Math.max(
        parseInteger(descriptor.minimumKey),
        Math.min(parseInteger(descriptor.maximumKey), state.key + direction),
      );
    const setKey = new NativeFunction(rva(descriptor.setKeyRva), 'int', ['int']);
    setKey(next);
  } else {
    throw new Error('未対応の再生操作です');
  }
  return currentRemoteState();
}

function performRemoteQueueAction(action, token) {
  const descriptor = DAM_TARGET_MANIFEST.hooks.remoteRequestQueue;
  const row = queueRowForToken(token);
  if (!row) throw new Error('予約情報が更新されています。再読み込みしてください');
  if (action === 'remove') {
    const remove = new NativeFunction(
      rva(descriptor.deleteRva),
      'int',
      ['pointer', 'int'],
    );
    if ((remove(NULL, row.queueId) & 0xff) === 0) {
      throw new Error('DAMが予約の取り消しを受け付けませんでした');
    }
  } else if (action === 'moveUp' || action === 'moveDown') {
    if (row.cutIn) throw new Error('割り込み予約の順番は変更できません');
    const count = Math.min(
      rva(descriptor.normalCountRva).readU32(),
      parseInteger(descriptor.maximumNormalEntries),
    );
    const target = row.index + (action === 'moveUp' ? -1 : 1);
    if (target < 0 || target >= count) return currentRemoteQueue();
    const reorder = new NativeFunction(
      rva(descriptor.reorderRva),
      'int',
      ['pointer', 'uint', 'uint'],
    );
    reorder(NULL, row.index, target);
  } else {
    throw new Error('未対応の予約操作です');
  }
  return currentRemoteQueue();
}

function installNativeHooks() {
  const setFile = DAM_TARGET_MANIFEST.hooks.playerSetFile;
  Interceptor.attach(rva(setFile.rva), {
    onEnter(args) {
      const highUrl = safeUtf8(args[setFile.highUrlArgument]);
      const lowUrl = safeUtf8(args[setFile.lowUrlArgument]);
      if (LOCAL_SERVER.test(highUrl) || LOCAL_SERVER.test(lowUrl)) {
        emitLog('現在セッションのローカルURLは二重登録しません');
        return;
      }
      const descriptor = resolveDescriptor(highUrl, lowUrl);
      if (!descriptor.videoId) {
        emitLog('従来形式の動画IDを取得できないため公式URLを使用します');
        return;
      }
      currentVideoId = descriptor.videoId;
      emitCurrentPlaybackMetadata(descriptor);
      send({ type: 'playback', ...descriptor });

      if (!config.replaceVideoUrls) {
        emitLog(`[${descriptor.videoId || 'unknown'}] 動画差し替えOFF: 公式URLを使用`);
        return;
      }
      requestSequence += 1;
      const requestId = `${Process.id}-${requestSequence}`;
      let reply = null;
      const operation = recv(`prepare-result:${requestId}`, (message) => {
        reply = message && message.payload ? message.payload : null;
      });
      send({ type: 'prepare', requestId, ...descriptor });
      operation.wait();
      if (!reply || reply.accepted !== true || !String(reply.localUrl || '').startsWith(LOCAL_PREFIX)) {
        emitLog(`[${descriptor.videoId || 'unknown'}] 登録失敗のため公式URLを使用`);
        return;
      }
      const localUrl = String(reply.localUrl);
      const highReplacement = Memory.allocUtf8String(localUrl);
      const lowReplacement = Memory.allocUtf8String(localUrl);
      retainedStrings.push(highReplacement, lowReplacement);
      if (retainedStrings.length > 512) retainedStrings.splice(0, 256);
      args[setFile.highUrlArgument] = highReplacement;
      args[setFile.lowUrlArgument] = lowReplacement;
      send({ type: 'rewritten', ...descriptor });
    },
  });
}

function beginScoringSession() {
  if (!config.scoringEnabled || scoringSessionActive) return;
  scoringSessionActive = true;
  lastOrnamentTimestamp = -1;
  send({ type: 'scoring-start' });
}

function finishScoringSession() {
  if (scoringSessionActive) send({ type: 'scoring-stop' });
  scoringSessionActive = false;
  lastOrnamentTimestamp = -1;
}

function installScoringHooks() {
  const start = DAM_TARGET_MANIFEST.hooks.scoringStart;
  const stop = DAM_TARGET_MANIFEST.hooks.scoringStop;
  const ornament = DAM_TARGET_MANIFEST.hooks.realtimeVocalOrnament;

  Interceptor.attach(rva(start.rva), {
    onLeave(result) {
      if (result.toInt32() !== 0) beginScoringSession();
    },
  });

  Interceptor.attach(rva(stop.rva), {
    onLeave(result) {
      if (result.toInt32() !== 0) finishScoringSession();
    },
  });

  Interceptor.attach(rva(ornament.rva), {
    onEnter(args) {
      this.output = args[parseInteger(ornament.outputArgument)];
    },
    onLeave(result) {
      if (!config.scoringEnabled || result.toInt32() === 0) return;
      const output = this.output;
      if (!output || output.isNull()) return;
      try {
        const timestamp = output.add(parseInteger(ornament.timestampOffset)).readS32();
        if (timestamp <= lastOrnamentTimestamp) return;
        beginScoringSession();
        lastOrnamentTimestamp = timestamp;
        const count = parseInteger(ornament.techniqueCount);
        const stride = parseInteger(ornament.valueStride);
        for (let technique = 0; technique < count; technique += 1) {
          const value = output.add(technique * stride).readS32();
          if (value > 0) {
            send({
              type: 'scoring-technique',
              technique,
              value,
              timestamp,
            });
          }
        }
      } catch (_) {
        // Scoring display is observational; never affect DAM playback.
      }
    },
  });
}

function finishRemoteReservation(accepted, message) {
  const pending = pendingRemoteReservation;
  if (!pending) return;
  pendingRemoteReservation = null;
  send({
    type: 'remote-reserve-result',
    requestId: pending.requestId,
    accepted: accepted === true,
    videoId: pending.videoId,
    artist: pending.artist,
    title: pending.title,
    message: String(message || ''),
  });
}

function finishRemoteFavorite(accepted, message, favorite) {
  const pending = pendingRemoteFavorite;
  if (!pending) return;
  pendingRemoteFavorite = null;
  send({
    type: 'remote-favorite-result',
    requestId: pending.requestId,
    accepted: accepted === true,
    favorite: favorite === true,
    videoId: pending.videoId,
    artist: pending.artist,
    title: pending.title,
    message: String(message || ''),
  });
}

function finishRemoteDetail(requestInfo, errorMessage = '') {
  const pending = pendingRemoteDetail;
  if (!pending) return;
  pendingRemoteDetail = null;
  if (errorMessage) {
    send({
      type: 'remote-detail-result',
      requestId: pending.requestId,
      error: String(errorMessage),
    });
    return;
  }
  try {
    if (!requestInfo || requestInfo.isNull()) throw new Error('曲詳細が空です');
    const descriptor = DAM_TARGET_MANIFEST.hooks.remoteReservation;
    const baseValid = requestInfo
      .add(parseInteger(descriptor.requestValidOffset))
      .readU8() !== 0;
    const playTypes = [];
    if (baseValid) playTypes.push('standard');
    if (baseValid && requestInfo
      .add(parseInteger(descriptor.artistVideoCapabilityOffset))
      .readU8() !== 0) {
      playTypes.push('artistVideo');
    }
    if (baseValid &&
        requestInfo.add(parseInteger(descriptor.guideVocalCapabilityOffset)).readU8() !== 0 &&
        requestInfo.add(parseInteger(descriptor.guideVocalValidFlagOffset)).readU8() !== 0 &&
        requestInfo.add(parseInteger(descriptor.guideVocalValidityOffset)).readU8() !== 0) {
      playTypes.push('guideVocal');
    }
    const videoId = cleanId(safeCString(
      requestInfo.add(parseInteger(descriptor.sourceVideoIdOffset)),
      64,
    ));
    if (videoId && pending.row) pending.row.videoId = videoId;
    send({
      type: 'remote-detail-result',
      requestId: pending.requestId,
      detail: {
        videoId: videoId || pending.videoId,
        startLyric: cleanText(safeUtf16(
          requestInfo.add(parseInteger(descriptor.sourceStartLyricOffset)),
          parseInteger(descriptor.sourceStartLyricCapacityChars),
        )),
        originalKey: requestInfo
          .add(parseInteger(descriptor.originalKeyOffset))
          .readS32(),
        playTypes,
      },
    });
  } catch (error) {
    send({
      type: 'remote-detail-result',
      requestId: pending.requestId,
      error: `DAMの曲詳細を読み取れません: ${error}`,
    });
  }
}

function damRequestContextReady() {
  const descriptor = DAM_TARGET_MANIFEST.hooks.remoteReservation;
  for (const rvaValue of [
    descriptor.primaryRequestContextRva,
    descriptor.fallbackRequestContextRva,
  ]) {
    try {
      const pair = rva(rvaValue);
      if (!pair.readPointer().isNull() &&
          !pair.add(Process.pointerSize).readPointer().isNull()) {
        return true;
      }
    } catch (_) {
      return false;
    }
  }
  return false;
}

function selectPlayType(requestInfo, requested) {
  const descriptor = DAM_TARGET_MANIFEST.hooks.remoteReservation;
  const guideVocalAvailable = requestInfo
    .add(parseInteger(descriptor.guideVocalCapabilityOffset))
    .readU8() !== 0;
  const artistVideoAvailable = requestInfo
    .add(parseInteger(descriptor.artistVideoCapabilityOffset))
    .readU8() !== 0;
  if (requested === 'guideVocal') {
    if (!guideVocalAvailable) throw new Error('この曲はガイドボーカルに対応していません');
    return 1;
  }
  if (requested === 'artistVideo') {
    if (!artistVideoAvailable) throw new Error('この曲は本人映像に対応していません');
    return 2;
  }
  return artistVideoAvailable ? 2 : 0;
}

function selectScoringContent(requestInfo, requested) {
  const descriptor = DAM_TARGET_MANIFEST.hooks.globalScoring;
  const enabled = requested || currentGlobalScoring();
  if (!enabled) return descriptor.disabledValue;
  return requestInfo.add(parseInteger(descriptor.requestCapabilityOffset)).readU8() !== 0
    ? descriptor.enabledValue
    : descriptor.disabledValue;
}

function buildPreparedRequestInfo(requestInfo, descriptor, options) {
  if (requestInfo.add(parseInteger(descriptor.requestValidOffset)).readU8() === 0) {
    throw new Error('DAMの曲詳細が予約可能な状態ではありません');
  }
  const size = parseInteger(descriptor.preparedInfoSize);
  const prepared = Memory.alloc(size);
  prepared.writeByteArray(new Uint8Array(size));

  // FUN_1400eb710 builds the queue-facing 0x46e-byte record from the larger
  // DkkMusicRequestInfo. Reproduce that data mapping without touching any
  // RequestWindow globals or callbacks.
  const selectedKey = options.originalKey
    ? requestInfo.add(parseInteger(descriptor.originalKeyOffset)).readS32()
    : options.key;
  prepared.add(parseInteger(descriptor.preparedKeyOffset)).writeS32(selectedKey);
  prepared.add(4).writeU8(requestInfo.add(8).readU8());
  prepared.add(8).writeU32(requestInfo.add(0x0c).readU32());
  const playType = selectPlayType(requestInfo, options.playType);
  prepared.add(parseInteger(descriptor.preparedPlayTypeOffset)).writeU32(playType);
  prepared.add(parseInteger(descriptor.preparedContentOffset)).writeU32(
    selectScoringContent(requestInfo, options.scoring),
  );

  let context = rva(descriptor.primaryRequestContextRva);
  if (context.readPointer().isNull()) {
    context = rva(descriptor.fallbackRequestContextRva);
  }
  prepared.add(0x18).writePointer(context.readPointer());
  prepared.add(0x20).writePointer(context.add(Process.pointerSize).readPointer());

  Memory.copy(
    prepared.add(parseInteger(descriptor.preparedTitleOffset)),
    requestInfo.add(parseInteger(descriptor.sourceTitleOffset)),
    0x200,
  );
  Memory.copy(
    prepared.add(parseInteger(descriptor.preparedArtistOffset)),
    requestInfo.add(parseInteger(descriptor.sourceArtistOffset)),
    0x200,
  );
  Memory.copy(
    prepared.add(parseInteger(descriptor.preparedTailOffset)),
    requestInfo.add(parseInteger(descriptor.sourceTailOffset)),
    parseInteger(descriptor.tailLength),
  );
  Memory.copy(
    prepared.add(parseInteger(descriptor.preparedOptionsOffset)),
    requestInfo.add(parseInteger(descriptor.sourceOptionsOffset)),
    4,
  );
  let validityOffset = 0x4a8;
  if (playType === 1 && requestInfo.add(0x4ab).readU8() !== 0) {
    validityOffset = 0x4aa;
  } else if (requestInfo.add(0x4a9).readU8() === 0) {
    throw new Error('この曲は指定した演奏タイプで予約できません');
  }
  prepared.add(0x46d).writeU8(requestInfo.add(validityOffset).readU8());
  return prepared;
}

function enqueueRemoteReservation(requestInfo) {
  if (!pendingRemoteReservation) return false;
  const descriptor = DAM_TARGET_MANIFEST.hooks.remoteReservation;
  if (!requestInfo || requestInfo.isNull()) return false;
  const prepared = buildPreparedRequestInfo(
    requestInfo,
    descriptor,
    pendingRemoteReservation.options,
  );
  const payload = requestInfo.add(parseInteger(descriptor.requestPayloadOffset));
  if (pendingRemoteReservation.mode === 'cutIn') {
    const enqueue = new NativeFunction(
      rva(descriptor.enqueueCutInRva),
      'uchar',
      ['pointer', 'pointer', 'pointer'],
    );
    return (enqueue(NULL, prepared, payload) & 0xff) !== 0;
  }
  const count = Memory.alloc(4);
  count.writeU32(0);
  const enqueue = new NativeFunction(
    rva(descriptor.enqueueNormalRva),
    'uchar',
    ['pointer', 'pointer', 'pointer', 'pointer'],
  );
  return (enqueue(NULL, prepared, count, payload) & 0xff) !== 0;
}

function withTemporaryCodePatches(descriptors, action) {
  const restored = [];
  try {
    for (const descriptor of descriptors || []) {
      const address = rva(descriptor.rva);
      const expected = hexBytes(descriptor.expectedBytes);
      const replacement = hexBytes(descriptor.replacementBytes);
      if (expected.length !== replacement.length) {
        throw new Error(`temporary patch size mismatch at ${descriptor.rva}`);
      }
      const current = new Uint8Array(address.readByteArray(expected.length));
      if (!current.every((value, index) => value === expected[index])) {
        throw new Error(`temporary patch verification failed at ${descriptor.rva}`);
      }
      Memory.patchCode(address, replacement.length, (code) => {
        code.writeByteArray(replacement);
      });
      restored.push({ address, expected });
    }
    Interceptor.flush();
    return action();
  } finally {
    for (let index = restored.length - 1; index >= 0; index -= 1) {
      const patch = restored[index];
      Memory.patchCode(patch.address, patch.expected.length, (code) => {
        code.writeByteArray(patch.expected);
      });
    }
    Interceptor.flush();
  }
}

function startRemoteFavoriteRegistration(requestInfo) {
  const favorites = DAM_TARGET_MANIFEST.hooks.remoteFavorites;
  const reservation = DAM_TARGET_MANIFEST.hooks.remoteReservation;
  const keyAddress = rva(favorites.favoriteKeyRva);
  const bankAddress = rva(favorites.requestBankFlagRva);
  const savedKey = keyAddress.readByteArray(8);
  const savedBank = bankAddress.readU8();
  try {
    Memory.copy(
      keyAddress,
      requestInfo.add(parseInteger(favorites.favoriteKeyOffset)),
      8,
    );
    bankAddress.writeU8(0);
    let context = rva(reservation.primaryRequestContextRva);
    if (context.readPointer().isNull()) context = rva(reservation.fallbackRequestContextRva);
    pendingRemoteFavorite.phase = 'register';
    const register = new NativeFunction(rva(favorites.registerRva), 'void', ['pointer']);
    register(context);
  } catch (error) {
    finishRemoteFavorite(false, `お気に入りへ登録できません: ${error}`, false);
  } finally {
    keyAddress.writeByteArray(savedKey);
    bankAddress.writeU8(savedBank);
  }
}

function requestRemoteSongDetail(row, listRow, actionName) {
  const reservation = DAM_TARGET_MANIFEST.hooks.remoteReservation;
  const requestDescriptor = listRow
    ? DAM_TARGET_MANIFEST.hooks.remoteCatalog.favorites
    : reservation;
  return runOnDamMainThread(actionName, () => {
    if (!damRequestContextReady()) {
      throw new Error('DAMが曲詳細を取得可能になるまでお待ちください');
    }
    const request = new NativeFunction(
      rva(listRow ? requestDescriptor.detailEntryRva : requestDescriptor.detailRequestRva),
      'void',
      listRow ? [] : ['pointer'],
    );
    const transientUiState = listRow
      ? requestDescriptor.detailTransientUiState
      : reservation.transientUiState;
    const snapshots = transientUiState.map((range) => {
      const address = rva(range.rva);
      const length = parseInteger(range.length);
      return { address, bytes: address.readByteArray(length) };
    });
    try {
      if (listRow) {
        const modeAddress = rva(requestDescriptor.listModeRva);
        const indexAddress = rva(requestDescriptor.selectedIndexRva);
        const savedMode = modeAddress.readU32();
        const savedIndex = indexAddress.readU32();
        try {
          modeAddress.writeU32(row.listMode);
          indexAddress.writeU32(row.listIndex);
          request();
        } finally {
          modeAddress.writeU32(savedMode);
          indexAddress.writeU32(savedIndex);
        }
      } else {
        request(row.compact);
      }
    } finally {
      for (const snapshot of snapshots) snapshot.address.writeByteArray(snapshot.bytes);
    }
    return true;
  });
}

function installRemoteControlHooks() {
  const search = DAM_TARGET_MANIFEST.hooks.remoteSearch;
  const catalog = DAM_TARGET_MANIFEST.hooks.remoteCatalog;
  const reservation = DAM_TARGET_MANIFEST.hooks.remoteReservation;
  const favorites = DAM_TARGET_MANIFEST.hooks.remoteFavorites;

  const finishSearchError = (message) => {
    const pending = pendingRemoteSearch;
    if (!pending) return false;
    pendingRemoteSearch = null;
    send({
      type: 'remote-search-result',
      requestId: pending.requestId,
      query: pending.query,
      mode: pending.mode,
      total: 0,
      rows: [],
      error: message,
    });
    return true;
  };

  const completeSongs = (first, countValue, totalValue, descriptor) => {
    const pending = pendingRemoteSearch;
    if (!pending) return false;
    pendingRemoteSearch = null;
    const count = Math.min(countValue, parseInteger(descriptor.maximumResults));
    const stride = parseInteger(descriptor.recordStride);
    const compactOffset = parseInteger(descriptor.compactOffset || 0);
    const compactSize = descriptor.compactSize == null
      ? 0
      : parseInteger(descriptor.compactSize);
    const favorite = pending.mode === 'favorites';
    const history = pending.mode === 'history';
    const rows = [];
    for (let index = 0; index < count; index += 1) {
      const record = first.add(index * stride);
      const videoId = descriptor.videoIdOffset == null
        ? ''
        : cleanId(
          safeCString(record.add(parseInteger(descriptor.videoIdOffset)), 128),
        );
      const title = cleanText(
        safeCString(record.add(parseInteger(descriptor.titleOffset)), 768),
      );
      const artist = cleanText(
        safeCString(record.add(parseInteger(descriptor.artistOffset)), 768),
      );
      if (!favorite && !history && !videoId) continue;
      const token = `${pending.requestId}_${index}`;
      let compact = null;
      if (!favorite && !history) {
        compact = Memory.alloc(compactSize);
        Memory.copy(compact, record.add(compactOffset), compactSize);
      }
      const row = {
        compact,
        videoId,
        artist,
        title,
        kind: 'song',
        favorite,
        history,
      };
      if (favorite || history) {
        row.listMode = parseInteger(descriptor.listMode);
        row.listIndex = index;
      }
      if (favorite) row.favoriteIndex = index;
      remoteSearchRows.set(token, row);
      rows.push({ token, videoId, artist, title, kind: 'song', favorite, history });
    }
    while (remoteSearchRows.size > 400) {
      remoteSearchRows.delete(remoteSearchRows.keys().next().value);
    }
    send({
      type: 'remote-search-result',
      requestId: pending.requestId,
      query: pending.query,
      mode: pending.mode,
      total: totalValue,
      rows,
    });
    return true;
  };

  const completeArtists = (first, countValue, totalValue) => {
    const pending = pendingRemoteSearch;
    if (!pending) return false;
    pendingRemoteSearch = null;
    const descriptor = catalog.artist;
    const count = Math.min(countValue, parseInteger(descriptor.maximumResults));
    const stride = parseInteger(descriptor.recordStride);
    const rows = [];
    for (let index = 0; index < count; index += 1) {
      const name = cleanText(
        safeCString(
          first.add(index * stride + parseInteger(descriptor.nameOffset)),
          768,
        ),
      );
      if (!name) continue;
      const token = `${pending.requestId}_${index}`;
      remoteSearchRows.set(token, { kind: 'artist', artist: name });
      rows.push({
        token,
        videoId: '',
        artist: name,
        title: '',
        kind: 'artist',
        favorite: false,
      });
    }
    send({
      type: 'remote-search-result',
      requestId: pending.requestId,
      query: pending.query,
      mode: pending.mode,
      total: totalValue,
      rows,
    });
    return true;
  };

  const replaceResult = (descriptor, argumentCount, handler) => {
    const address = rva(descriptor.resultRva);
    const signature = Array(argumentCount).fill('pointer');
    const original = new NativeFunction(address, 'void', signature);
    const replacement = new NativeCallback((...args) => {
      if (handler(args)) return;
      original(...args);
    }, 'void', signature);
    Interceptor.replace(address, replacement);
    retainedNativeCallbacks.push(replacement);
  };

  replaceResult(search, 4, (args) =>
    pendingRemoteSearch && pendingRemoteSearch.mode === 'keyword' && completeSongs(
      args[1],
      args[2].toUInt32(),
      args[3].toUInt32(),
      search,
    ));
  replaceResult(catalog.title, 3, (args) =>
    pendingRemoteSearch && pendingRemoteSearch.mode === 'title' && completeSongs(
      args[1],
      args[2].toUInt32(),
      args[2].toUInt32(),
      catalog.title,
    ));
  replaceResult(catalog.artist, 3, (args) =>
    pendingRemoteSearch && pendingRemoteSearch.mode === 'artist' && completeArtists(
      args[1],
      args[2].toUInt32(),
      args[2].toUInt32(),
    ));
  replaceResult(catalog.new, 3, (args) =>
    pendingRemoteSearch && pendingRemoteSearch.mode === 'new' && completeSongs(
      args[1].add(parseInteger(catalog.new.firstItemOffset)),
      args[2].toUInt32(),
      args[2].toUInt32(),
      catalog.new,
    ));
  replaceResult(catalog.ranking, 4, (args) =>
    pendingRemoteSearch && pendingRemoteSearch.mode === 'ranking' && completeSongs(
      args[1],
      args[2].toUInt32(),
      args[3].toUInt32(),
      catalog.ranking,
    ));
  replaceResult(catalog.history, 4, (args) => {
    if (!pendingRemoteSearch || pendingRemoteSearch.mode !== 'history') return false;
    const copyList = new NativeFunction(
      rva(catalog.history.copyListRva),
      'void',
      ['pointer', 'pointer', 'pointer', 'pointer'],
    );
    copyList(args[1], NULL, args[2], args[3]);
    return completeSongs(
      args[1],
      args[2].toUInt32(),
      args[3].toUInt32(),
      catalog.history,
    );
  });

  const favoriteResultAddress = rva(catalog.favorites.resultRva);
  const callOriginalFavoriteResult = new NativeFunction(
    favoriteResultAddress,
    'void',
    ['pointer', 'pointer', 'pointer'],
  );
  const favoriteResultReplacement = new NativeCallback(
    (callback, firstPointer, countPointer) => {
      if (!pendingRemoteSearch || pendingRemoteSearch.mode !== 'favorites') {
        callOriginalFavoriteResult(callback, firstPointer, countPointer);
        return;
      }
      const first = firstPointer.readPointer();
      const count = countPointer.readU32();
      const copyList = new NativeFunction(
        rva(catalog.favorites.copyListRva),
        'void',
        ['pointer', 'pointer'],
      );
      copyList(first, ptr(count));
      completeSongs(first, count, count, catalog.favorites);
    },
    'void',
    ['pointer', 'pointer', 'pointer'],
  );
  Interceptor.replace(favoriteResultAddress, favoriteResultReplacement);
  retainedNativeCallbacks.push(favoriteResultReplacement);

  const historyErrorAddress = rva(catalog.history.errorRva);
  const callOriginalHistoryError = new NativeFunction(
    historyErrorAddress,
    'void',
    ['pointer', 'pointer'],
  );
  const historyErrorReplacement = new NativeCallback((callback, message) => {
    if (pendingRemoteSearch && pendingRemoteSearch.mode === 'history') {
      finishSearchError('DAMの演奏履歴を取得できませんでした');
      return;
    }
    callOriginalHistoryError(callback, message);
  }, 'void', ['pointer', 'pointer']);
  Interceptor.replace(historyErrorAddress, historyErrorReplacement);
  retainedNativeCallbacks.push(historyErrorReplacement);

  const favoriteDetailResultAddress = rva(catalog.favorites.detailResultRva);
  const callOriginalFavoriteDetailResult = new NativeFunction(
    favoriteDetailResultAddress,
    'void',
    ['pointer', 'pointer'],
  );
  const favoriteDetailResultReplacement = new NativeCallback((callback, requestInfo) => {
    if (pendingRemoteFavorite && pendingRemoteFavorite.phase === 'detail') {
      startRemoteFavoriteRegistration(requestInfo);
      return;
    }
    if (pendingRemoteDetail && pendingRemoteDetail.source === 'list') {
      finishRemoteDetail(requestInfo);
      return;
    }
    if (!pendingRemoteReservation || pendingRemoteReservation.source !== 'list') {
      callOriginalFavoriteDetailResult(callback, requestInfo);
      return;
    }
    let accepted = false;
    let message = 'DAMが予約を受け付けませんでした';
    try {
      const publicId = cleanId(safeCString(
        requestInfo.add(parseInteger(reservation.sourceVideoIdOffset)),
        64,
      ));
      if (publicId) pendingRemoteReservation.videoId = publicId;
      accepted = enqueueRemoteReservation(requestInfo);
      if (accepted) message = '予約しました';
    } catch (error) {
      message = `DAMの予約キューを更新できません: ${error}`;
    }
    finishRemoteReservation(accepted, message);
  }, 'void', ['pointer', 'pointer']);
  Interceptor.replace(favoriteDetailResultAddress, favoriteDetailResultReplacement);
  retainedNativeCallbacks.push(favoriteDetailResultReplacement);

  const favoriteDetailErrorAddress = rva(catalog.favorites.detailErrorRva);
  const callOriginalFavoriteDetailError = new NativeFunction(
    favoriteDetailErrorAddress,
    'void',
    ['pointer', 'pointer'],
  );
  const favoriteDetailErrorReplacement = new NativeCallback((callback, message) => {
    if (pendingRemoteFavorite && pendingRemoteFavorite.phase === 'detail') {
      finishRemoteFavorite(false, 'DAMの曲詳細取得に失敗しました', false);
      return;
    }
    if (pendingRemoteDetail && pendingRemoteDetail.source === 'list') {
      finishRemoteDetail(NULL, 'DAMの一覧から曲詳細を取得できませんでした');
      return;
    }
    if (pendingRemoteReservation && pendingRemoteReservation.source === 'list') {
      finishRemoteReservation(false, 'DAMの一覧から曲詳細を取得できませんでした');
      return;
    }
    callOriginalFavoriteDetailError(callback, message);
  }, 'void', ['pointer', 'pointer']);
  Interceptor.replace(favoriteDetailErrorAddress, favoriteDetailErrorReplacement);
  retainedNativeCallbacks.push(favoriteDetailErrorReplacement);

  const searchStartAddress = rva(search.startUiRva);
  const callOriginalSearchStart = new NativeFunction(searchStartAddress, 'void', []);
  const searchStartReplacement = new NativeCallback(() => {
    if (pendingRemoteSearch) return;
    callOriginalSearchStart();
  }, 'void', []);
  Interceptor.replace(searchStartAddress, searchStartReplacement);
  retainedNativeCallbacks.push(searchStartReplacement);

  const searchErrorAddress = rva(search.errorUiRva);
  const callOriginalSearchError = new NativeFunction(searchErrorAddress, 'void', ['pointer']);
  const searchErrorReplacement = new NativeCallback((message) => {
    if (finishSearchError('該当する曲または歌手がありません')) return;
    callOriginalSearchError(message);
  }, 'void', ['pointer']);
  Interceptor.replace(searchErrorAddress, searchErrorReplacement);
  retainedNativeCallbacks.push(searchErrorReplacement);

  const catalogErrorAddress = rva(catalog.catalogErrorRva);
  const callOriginalCatalogError = new NativeFunction(
    catalogErrorAddress,
    'void',
    ['pointer', 'int'],
  );
  const catalogErrorReplacement = new NativeCallback((message, detail) => {
    if (finishSearchError('一覧を取得できませんでした')) return;
    callOriginalCatalogError(message, detail);
  }, 'void', ['pointer', 'int']);
  Interceptor.replace(catalogErrorAddress, catalogErrorReplacement);
  retainedNativeCallbacks.push(catalogErrorReplacement);

  // Common ClubDAM start callback. Remote work consumes it so the TV scene
  // never receives loading state; DAM-originated operations keep the original.
  const reservationStartAddress = rva(reservation.startUiRva);
  const callOriginalReservationStart = new NativeFunction(reservationStartAddress, 'void', []);
  const reservationStartReplacement = new NativeCallback(() => {
    if (pendingRemoteSearch || pendingRemoteDetail ||
        pendingRemoteReservation || pendingRemoteFavorite) return;
    callOriginalReservationStart();
  }, 'void', []);
  Interceptor.replace(reservationStartAddress, reservationStartReplacement);
  retainedNativeCallbacks.push(reservationStartReplacement);

  const reservationResultAddress = rva(reservation.resultUiRva);
  const callOriginalReservationResult = new NativeFunction(
    reservationResultAddress,
    'void',
    ['pointer', 'pointer'],
  );
  const reservationResultReplacement = new NativeCallback((callback, requestInfo) => {
    if (pendingRemoteFavorite && pendingRemoteFavorite.phase === 'detail') {
      startRemoteFavoriteRegistration(requestInfo);
      return;
    }
    if (pendingRemoteDetail && pendingRemoteDetail.source === 'search') {
      finishRemoteDetail(requestInfo);
      return;
    }
    if (!pendingRemoteReservation) {
      callOriginalReservationResult(callback, requestInfo);
      return;
    }
    let accepted = false;
    let message = 'DAMが予約を受け付けませんでした';
    try {
      accepted = enqueueRemoteReservation(requestInfo);
      if (accepted) message = '予約しました';
    } catch (error) {
      message = `DAMの予約キューを更新できません: ${error}`;
    }
    finishRemoteReservation(accepted, message);
  }, 'void', ['pointer', 'pointer']);
  Interceptor.replace(reservationResultAddress, reservationResultReplacement);
  retainedNativeCallbacks.push(reservationResultReplacement);

  const reservationErrorAddress = rva(reservation.errorUiRva);
  const callOriginalReservationError = new NativeFunction(
    reservationErrorAddress,
    'void',
    ['pointer', 'pointer'],
  );
  const reservationErrorReplacement = new NativeCallback((callback, message) => {
    if (pendingRemoteFavorite && pendingRemoteFavorite.phase === 'detail') {
      finishRemoteFavorite(false, 'DAMの曲詳細取得に失敗しました', false);
      return;
    }
    if (pendingRemoteDetail && pendingRemoteDetail.source === 'search') {
      finishRemoteDetail(NULL, 'DAMの曲詳細取得に失敗しました');
      return;
    }
    if (pendingRemoteReservation) {
      finishRemoteReservation(false, 'DAMの曲詳細取得に失敗しました');
      return;
    }
    callOriginalReservationError(callback, message);
  }, 'void', ['pointer', 'pointer']);
  Interceptor.replace(reservationErrorAddress, reservationErrorReplacement);
  retainedNativeCallbacks.push(reservationErrorReplacement);

  const registerSuccessAddress = rva(favorites.registerSuccessRva);
  const callOriginalRegisterSuccess = new NativeFunction(
    registerSuccessAddress,
    'void',
    ['pointer'],
  );
  const registerSuccessReplacement = new NativeCallback((callback) => {
    if (pendingRemoteFavorite && pendingRemoteFavorite.phase === 'register') {
      finishRemoteFavorite(true, 'お気に入りに登録しました', true);
      return;
    }
    callOriginalRegisterSuccess(callback);
  }, 'void', ['pointer']);
  Interceptor.replace(registerSuccessAddress, registerSuccessReplacement);
  retainedNativeCallbacks.push(registerSuccessReplacement);

  const registerErrorAddress = rva(favorites.registerErrorRva);
  const callOriginalRegisterError = new NativeFunction(
    registerErrorAddress,
    'void',
    ['pointer', 'pointer'],
  );
  const registerErrorReplacement = new NativeCallback((callback, message) => {
    if (pendingRemoteFavorite && pendingRemoteFavorite.phase === 'register') {
      finishRemoteFavorite(false, 'お気に入りへ登録できませんでした', false);
      return;
    }
    callOriginalRegisterError(callback, message);
  }, 'void', ['pointer', 'pointer']);
  Interceptor.replace(registerErrorAddress, registerErrorReplacement);
  retainedNativeCallbacks.push(registerErrorReplacement);

  const deleteSuccessAddress = rva(favorites.deleteSuccessRva);
  const callOriginalDeleteSuccess = new NativeFunction(
    deleteSuccessAddress,
    'void',
    ['pointer'],
  );
  const deleteSuccessReplacement = new NativeCallback((callback) => {
    if (pendingRemoteFavorite && pendingRemoteFavorite.phase === 'delete') {
      finishRemoteFavorite(true, 'お気に入りから削除しました', false);
      return;
    }
    callOriginalDeleteSuccess(callback);
  }, 'void', ['pointer']);
  Interceptor.replace(deleteSuccessAddress, deleteSuccessReplacement);
  retainedNativeCallbacks.push(deleteSuccessReplacement);

  const deleteErrorAddress = rva(favorites.deleteErrorRva);
  const callOriginalDeleteError = new NativeFunction(
    deleteErrorAddress,
    'void',
    ['pointer', 'pointer'],
  );
  const deleteErrorReplacement = new NativeCallback((callback, message) => {
    if (pendingRemoteFavorite && pendingRemoteFavorite.phase === 'delete') {
      finishRemoteFavorite(false, 'お気に入りから削除できませんでした', true);
      return;
    }
    callOriginalDeleteError(callback, message);
  }, 'void', ['pointer', 'pointer']);
  Interceptor.replace(deleteErrorAddress, deleteErrorReplacement);
  retainedNativeCallbacks.push(deleteErrorReplacement);
}

function validateHooks() {
  verifyPrefix('playerSetFile', DAM_TARGET_MANIFEST.hooks.playerSetFile);
  verifyPrefix('scoringStart', DAM_TARGET_MANIFEST.hooks.scoringStart);
  verifyPrefix('scoringStop', DAM_TARGET_MANIFEST.hooks.scoringStop);
  verifyPrefix(
    'realtimeVocalOrnament',
    DAM_TARGET_MANIFEST.hooks.realtimeVocalOrnament,
  );
  const remoteSearch = DAM_TARGET_MANIFEST.hooks.remoteSearch;
  verifyPrefix('remoteSearchEntry', {
    rva: remoteSearch.entryRva,
    expectedPrefix: remoteSearch.entryExpectedPrefix,
  });
  verifyPrefix('remoteSearchStart', {
    rva: remoteSearch.startUiRva,
    expectedPrefix: remoteSearch.startUiExpectedPrefix,
  });
  verifyPrefix('remoteSearchResult', {
    rva: remoteSearch.resultRva,
    expectedPrefix: remoteSearch.resultExpectedPrefix,
  });
  verifyPrefix('remoteSearchError', {
    rva: remoteSearch.errorUiRva,
    expectedPrefix: remoteSearch.errorUiExpectedPrefix,
  });
  const remoteCatalog = DAM_TARGET_MANIFEST.hooks.remoteCatalog;
  for (const mode of ['title', 'artist', 'new', 'ranking', 'history', 'favorites']) {
    const descriptor = remoteCatalog[mode];
    verifyPrefix(`remoteCatalog.${mode}.entry`, {
      rva: descriptor.entryRva,
      expectedPrefix: descriptor.entryExpectedPrefix,
    });
    verifyPrefix(`remoteCatalog.${mode}.result`, {
      rva: descriptor.resultRva,
      expectedPrefix: descriptor.resultExpectedPrefix,
    });
  }
  verifyPrefix('remoteCatalog.error', {
    rva: remoteCatalog.catalogErrorRva,
    expectedPrefix: remoteCatalog.catalogErrorExpectedPrefix,
  });
  verifyPrefix('remoteCatalog.favorites.copyList', {
    rva: remoteCatalog.favorites.copyListRva,
    expectedPrefix: remoteCatalog.favorites.copyListExpectedPrefix,
  });
  verifyPrefix('remoteCatalog.favorites.detailEntry', {
    rva: remoteCatalog.favorites.detailEntryRva,
    expectedPrefix: remoteCatalog.favorites.detailEntryExpectedPrefix,
  });
  verifyPrefix('remoteCatalog.favorites.detailResult', {
    rva: remoteCatalog.favorites.detailResultRva,
    expectedPrefix: remoteCatalog.favorites.detailResultExpectedPrefix,
  });
  verifyPrefix('remoteCatalog.favorites.detailError', {
    rva: remoteCatalog.favorites.detailErrorRva,
    expectedPrefix: remoteCatalog.favorites.detailErrorExpectedPrefix,
  });
  verifyPrefix('remoteCatalog.history.error', {
    rva: remoteCatalog.history.errorRva,
    expectedPrefix: remoteCatalog.history.errorExpectedPrefix,
  });
  verifyPrefix('remoteCatalog.history.copyList', {
    rva: remoteCatalog.history.copyListRva,
    expectedPrefix: remoteCatalog.history.copyListExpectedPrefix,
  });
  for (const [index, patch] of
    (remoteCatalog.history.remoteOnlyPreludePatches || []).entries()) {
    verifyPrefix(`remoteCatalog.history.remoteOnlyPrelude.${index}`, {
      rva: patch.rva,
      expectedPrefix: patch.expectedBytes,
    });
  }
  const remoteReservation = DAM_TARGET_MANIFEST.hooks.remoteReservation;
  verifyPrefix('remoteDetailRequest', {
    rva: remoteReservation.detailRequestRva,
    expectedPrefix: remoteReservation.detailRequestExpectedPrefix,
  });
  verifyPrefix('remoteReservationStart', {
    rva: remoteReservation.startUiRva,
    expectedPrefix: remoteReservation.startUiExpectedPrefix,
  });
  verifyPrefix('remoteReservationResult', {
    rva: remoteReservation.resultUiRva,
    expectedPrefix: remoteReservation.resultUiExpectedPrefix,
  });
  verifyPrefix('remoteReservationError', {
    rva: remoteReservation.errorUiRva,
    expectedPrefix: remoteReservation.errorUiExpectedPrefix,
  });
  verifyPrefix('remoteEnqueueCutIn', {
    rva: remoteReservation.enqueueCutInRva,
    expectedPrefix: remoteReservation.enqueueCutInExpectedPrefix,
  });
  verifyPrefix('remoteEnqueueNormal', {
    rva: remoteReservation.enqueueNormalRva,
    expectedPrefix: remoteReservation.enqueueNormalExpectedPrefix,
  });
  const remoteFavorites = DAM_TARGET_MANIFEST.hooks.remoteFavorites;
  for (const [name, rvaValue, expectedPrefix] of [
    ['remoteFavoriteRegister', remoteFavorites.registerRva, remoteFavorites.registerExpectedPrefix],
    ['remoteFavoriteRegisterSuccess', remoteFavorites.registerSuccessRva, remoteFavorites.registerSuccessExpectedPrefix],
    ['remoteFavoriteRegisterError', remoteFavorites.registerErrorRva, remoteFavorites.registerErrorExpectedPrefix],
    ['remoteFavoriteDelete', remoteFavorites.deleteRva, remoteFavorites.deleteExpectedPrefix],
    ['remoteFavoriteDeleteSuccess', remoteFavorites.deleteSuccessRva, remoteFavorites.deleteSuccessExpectedPrefix],
    ['remoteFavoriteDeleteError', remoteFavorites.deleteErrorRva, remoteFavorites.deleteErrorExpectedPrefix],
  ]) {
    verifyPrefix(name, { rva: rvaValue, expectedPrefix });
  }
  const playbackControl = DAM_TARGET_MANIFEST.hooks.remotePlaybackControl;
  for (const [name, rvaValue, expectedPrefix] of [
    ['remotePause', playbackControl.pauseRva, playbackControl.pauseExpectedPrefix],
    ['remoteStop', playbackControl.stopRva, playbackControl.stopExpectedPrefix],
    ['remoteRestart', playbackControl.restartRva, playbackControl.restartExpectedPrefix],
    ['remoteSetKey', playbackControl.setKeyRva, playbackControl.setKeyExpectedPrefix],
  ]) {
    verifyPrefix(name, { rva: rvaValue, expectedPrefix });
  }
  const requestQueue = DAM_TARGET_MANIFEST.hooks.remoteRequestQueue;
  verifyPrefix('remoteQueueDelete', {
    rva: requestQueue.deleteRva,
    expectedPrefix: requestQueue.deleteExpectedPrefix,
  });
  verifyPrefix('remoteQueueReorder', {
    rva: requestQueue.reorderRva,
    expectedPrefix: requestQueue.reorderExpectedPrefix,
  });
  for (const [name, descriptor] of Object.entries(DAM_TARGET_MANIFEST.patches)) {
    const expected = hexBytes(descriptor.expected);
    const actual = readBytes(rva(descriptor.rva), expected.length);
    if (!sameBytes(actual, expected)) {
      const message = `${name} の初期命令列が一致しません ` +
        `(expected=${bytesText(expected)}, actual=${bytesText(actual)})`;
      send({ type: 'patch-error', message });
      throw new Error(message);
    }
  }
}

rpc.exports = {
  initialize(next) {
    if (initialized) return true;
    validateHooks();
    applyConfig(next);
    installNativeHooks();
    installScoringHooks();
    installRemoteControlHooks();
    hooksInstalled = true;
    initialized = true;
    emitLog('検証済み再生経路・曲情報・採点表現監視を有効化しました');
    return true;
  },
  updateConfig(next) {
    if (!initialized) return false;
    applyConfig(next);
    return true;
  },
  restoreAll() {
    pendingRemoteSearch = null;
    pendingRemoteDetail = null;
    pendingRemoteReservation = null;
    pendingRemoteFavorite = null;
    cancelMainThreadTasks();
    currentVideoId = '';
    remoteSearchRows.clear();
    finishScoringSession();
    restorePatches();
    // Function replacements stay active until script unload so an in-flight
    // remote response cannot fall through to DAM's UI during shutdown.
    return true;
  },
  remoteSearch(requestId, query, mode) {
    if (!initialized) throw new Error('agent is not initialized');
    if (!damRequestContextReady()) throw new Error('DAMが検索可能になるまでお待ちください');
    const id = cleanCorrelationId(requestId);
    const normalizedMode = ['keyword', 'title', 'artist', 'new', 'ranking', 'favorites', 'history']
      .includes(String(mode)) ? String(mode) : 'keyword';
    const catalog = DAM_TARGET_MANIFEST.hooks.remoteCatalog;
    const descriptor = normalizedMode === 'keyword'
      ? DAM_TARGET_MANIFEST.hooks.remoteSearch
      : catalog[normalizedMode];
    const needsQuery = ['keyword', 'title', 'artist'].includes(normalizedMode);
    const normalizedQuery = needsQuery
      ? cleanSearchQuery(query, parseInteger(descriptor.queryCapacityChars))
      : '';
    if (!id || (needsQuery && !normalizedQuery)) {
      throw new Error('invalid remote search request');
    }
    if (pendingRemoteSearch || pendingRemoteDetail ||
        pendingRemoteReservation || pendingRemoteFavorite) {
      throw new Error('another remote request is running');
    }
    let buffer = NULL;
    if (needsQuery) {
      buffer = Memory.alloc(parseInteger(descriptor.queryCapacityChars) * 2);
      buffer.writeByteArray(
        new Uint8Array(parseInteger(descriptor.queryCapacityChars) * 2),
      );
      buffer.writeUtf16String(normalizedQuery);
    }
    pendingRemoteSearch = {
      requestId: id,
      query: normalizedQuery,
      mode: normalizedMode,
      buffer,
    };
    setTimeout(() => {
      if (pendingRemoteSearch && pendingRemoteSearch.requestId === id) {
        pendingRemoteSearch = null;
        send({
          type: 'remote-search-result',
          requestId: id,
          query: normalizedQuery,
          mode: normalizedMode,
          total: 0,
          rows: [],
          error: 'DAMの検索がタイムアウトしました',
        });
      }
    }, 15000);
    return runOnDamMainThread('リモコン検索', () => {
      if (!damRequestContextReady()) {
        throw new Error('DAMが検索可能になるまでお待ちください');
      }
      const nativeSearch = new NativeFunction(
        rva(descriptor.entryRva),
        'void',
        needsQuery ? ['pointer'] : [],
      );
      const transientState = descriptor.transientUiState || catalog.transientUiState;
      const snapshots = transientState.map((range) => {
        const address = rva(range.rva);
        const length = parseInteger(range.length);
        return { address, bytes: address.readByteArray(length) };
      });
      try {
        const invokeSearch = () => {
          if (needsQuery) nativeSearch(buffer);
          else nativeSearch();
        };
        // DAM's history entry begins with the same two UI-feedback calls as
        // its on-screen history button. A remote read must not make a button
        // sound or animate DAM, so omit those calls only for this synchronous
        // invocation and restore their original instructions immediately.
        if (normalizedMode === 'history') {
          withTemporaryCodePatches(descriptor.remoteOnlyPreludePatches, invokeSearch);
        } else {
          invokeSearch();
        }
      } finally {
        // The request owns its query and callbacks after this entry returns.
        // Restore all scene-related globals immediately so a remote lookup
        // cannot move or prime DAM's on-screen search scene.
        for (const snapshot of snapshots) {
          snapshot.address.writeByteArray(snapshot.bytes);
        }
      }
      return true;
    }).catch((error) => {
      if (pendingRemoteSearch && pendingRemoteSearch.requestId === id) {
        pendingRemoteSearch = null;
      }
      throw error;
    });
  },
  remoteDetail(requestId, token) {
    if (!initialized) throw new Error('agent is not initialized');
    if (!damRequestContextReady()) {
      throw new Error('DAMが曲詳細を取得可能になるまでお待ちください');
    }
    const id = cleanCorrelationId(requestId);
    const row = remoteSearchRows.get(String(token == null ? '' : token));
    const listRow = row && Number.isInteger(row.listMode) && Number.isInteger(row.listIndex);
    if (!id || !row || row.kind !== 'song' || (!row.compact && !listRow)) {
      throw new Error('invalid or expired search result');
    }
    if (pendingRemoteSearch || pendingRemoteDetail ||
        pendingRemoteReservation || pendingRemoteFavorite) {
      throw new Error('another remote request is running');
    }
    pendingRemoteDetail = {
      requestId: id,
      videoId: row.videoId,
      source: listRow ? 'list' : 'search',
      row,
    };
    setTimeout(() => {
      if (pendingRemoteDetail && pendingRemoteDetail.requestId === id) {
        finishRemoteDetail(NULL, 'DAMの曲詳細取得がタイムアウトしました');
      }
    }, 20000);
    return requestRemoteSongDetail(row, listRow, 'リモコン曲詳細').catch((error) => {
      if (pendingRemoteDetail && pendingRemoteDetail.requestId === id) {
        pendingRemoteDetail = null;
      }
      throw error;
    });
  },
  remoteReserve(requestId, token, options) {
    if (!initialized) throw new Error('agent is not initialized');
    if (!damRequestContextReady()) throw new Error('DAMが予約可能になるまでお待ちください');
    const id = cleanCorrelationId(requestId);
    const resultToken = String(token == null ? '' : token);
    const row = remoteSearchRows.get(resultToken);
    const source = options && typeof options === 'object' ? options : {};
    const reservationMode = ['normal', 'cutIn', 'originalKey'].includes(source.mode)
      ? source.mode
      : 'normal';
    const keyValue = Number.isInteger(source.key) ? source.key : 0;
    const playType = ['standard', 'guideVocal', 'artistVideo'].includes(source.playType)
      ? source.playType
      : 'standard';
    const listRow = row && Number.isInteger(row.listMode) && Number.isInteger(row.listIndex);
    if (!id || !row || row.kind !== 'song' || (!row.compact && !listRow)) {
      throw new Error('invalid or expired search result');
    }
    if (keyValue < -7 || keyValue > 7) throw new Error('invalid reservation key');
    if (pendingRemoteSearch || pendingRemoteDetail ||
        pendingRemoteReservation || pendingRemoteFavorite) {
      throw new Error('another remote request is running');
    }
    pendingRemoteReservation = {
      requestId: id,
      videoId: row.videoId,
      artist: row.artist,
      title: row.title,
      source: listRow ? 'list' : 'search',
      mode: reservationMode,
      options: {
        key: keyValue,
        originalKey: reservationMode === 'originalKey',
        scoring: source.scoring === true,
        playType,
      },
    };
    setTimeout(() => {
      if (pendingRemoteReservation && pendingRemoteReservation.requestId === id) {
        finishRemoteReservation(false, 'DAMの予約処理がタイムアウトしました');
      }
    }, 20000);
    return requestRemoteSongDetail(row, listRow, 'リモコン予約').catch((error) => {
      if (pendingRemoteReservation && pendingRemoteReservation.requestId === id) {
        pendingRemoteReservation = null;
      }
      throw error;
    });
  },
  remoteFavorite(requestId, token, action) {
    if (!initialized) throw new Error('agent is not initialized');
    if (!damRequestContextReady()) throw new Error('DAMが操作可能になるまでお待ちください');
    const id = cleanCorrelationId(requestId);
    const row = remoteSearchRows.get(String(token == null ? '' : token));
    const normalizedAction = action === 'remove' ? 'remove' : 'add';
    const listRow = row && Number.isInteger(row.listMode) && Number.isInteger(row.listIndex);
    if (!id || !row || row.kind !== 'song' ||
        (normalizedAction === 'add' && !row.compact && !listRow)) {
      throw new Error('invalid or expired search result');
    }
    if (pendingRemoteSearch || pendingRemoteDetail ||
        pendingRemoteReservation || pendingRemoteFavorite) {
      throw new Error('another remote request is running');
    }
    if (normalizedAction === 'remove' && !Number.isInteger(row.favoriteIndex)) {
      throw new Error('お気に入り一覧を更新してから削除してください');
    }
    pendingRemoteFavorite = {
      requestId: id,
      videoId: row.videoId,
      artist: row.artist,
      title: row.title,
      phase: normalizedAction === 'remove' ? 'delete' : 'detail',
    };
    setTimeout(() => {
      if (pendingRemoteFavorite && pendingRemoteFavorite.requestId === id) {
        finishRemoteFavorite(false, 'お気に入り操作がタイムアウトしました', row.favorite === true);
      }
    }, 20000);
    if (normalizedAction === 'add' && listRow) {
      return requestRemoteSongDetail(row, true, 'お気に入り操作').catch((error) => {
        if (pendingRemoteFavorite && pendingRemoteFavorite.requestId === id) {
          pendingRemoteFavorite = null;
        }
        throw error;
      });
    }
    return runOnDamMainThread('お気に入り操作', () => {
      if (normalizedAction === 'remove') {
        const remove = new NativeFunction(
          rva(DAM_TARGET_MANIFEST.hooks.remoteFavorites.deleteRva),
          'void',
          ['pointer'],
        );
        remove(ptr(row.favoriteIndex));
      } else {
        const request = new NativeFunction(
          rva(DAM_TARGET_MANIFEST.hooks.remoteReservation.detailRequestRva),
          'void',
          ['pointer'],
        );
        request(row.compact);
      }
      return true;
    }).catch((error) => {
      if (pendingRemoteFavorite && pendingRemoteFavorite.requestId === id) {
        pendingRemoteFavorite = null;
      }
      throw error;
    });
  },
  remoteState() {
    if (!initialized) throw new Error('agent is not initialized');
    return currentRemoteState();
  },
  remoteControl(action) {
    if (!initialized) throw new Error('agent is not initialized');
    const normalized = String(action == null ? '' : action);
    return runOnDamMainThread(
      `再生操作(${normalized})`,
      () => performRemoteControl(normalized),
    );
  },
  remoteQueue() {
    if (!initialized) throw new Error('agent is not initialized');
    return currentRemoteQueue();
  },
  remoteQueueAction(action, token) {
    if (!initialized) throw new Error('agent is not initialized');
    const normalizedAction = String(action == null ? '' : action);
    const normalizedToken = String(token == null ? '' : token);
    return runOnDamMainThread(
      `予約操作(${normalizedAction})`,
      () => performRemoteQueueAction(normalizedAction, normalizedToken),
    );
  },
};
