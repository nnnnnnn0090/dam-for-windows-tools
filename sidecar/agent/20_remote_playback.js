// Project: DAM for Windows Tools
// File: agent/20_remote_playback.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

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
