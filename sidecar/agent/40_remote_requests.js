// Project: DAM for Windows Tools
// File: agent/40_remote_requests.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

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
