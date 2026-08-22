// Project: DAM for Windows Tools
// File: agent/70_rpc_exports.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

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
