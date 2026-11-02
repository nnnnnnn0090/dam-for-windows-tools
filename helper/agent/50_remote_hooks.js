// Project: DAM for Windows Tools
// File: agent/50_remote_hooks.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

/** DAMの検索・曲詳細・予約・お気に入り結果を、画面を動かさずリモコンへ返すフックを設置します。 */
function installRemoteControlHooks() {
  const search = DAM_TARGET_MANIFEST.hooks.remoteSearch;
  const catalog = DAM_TARGET_MANIFEST.hooks.remoteCatalog;
  const reservation = DAM_TARGET_MANIFEST.hooks.remoteReservation;
  const favorites = DAM_TARGET_MANIFEST.hooks.remoteFavorites;

  /** 保留中検索だけをエラーで完了し、本体操作なら元コールバックへ渡せるよう判定します。 */
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

  /** DAM検索構造体を検証済み曲一覧へ変換し、操作用コピーをセッション内に保持します。 */
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

  /** 歌手検索構造体を曲一覧へ進むための歌手行へ変換します。 */
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

  /** 結果コールバックを置換し、リモコン要求でなければ元処理をそのまま呼びます。 */
  const replaceResult = (descriptor, argumentCount, handler) => {
    const address = rva(descriptor.resultRva);
    const signature = Array(argumentCount).fill('pointer');
    const original = new NativeFunction(address, 'void', signature);
    // 保留要求を消費できた場合だけ本体UIへの元結果通知を抑止します。
    const replacement = new NativeCallback((...args) => {
      if (handler(args)) return;
      original(...args);
    }, 'void', signature);
    Interceptor.replace(address, replacement);
    retainedNativeCallbacks.push(replacement);
  };

  // キーワード検索結果だけを保留中の同モード要求へ渡します。
  replaceResult(search, 4, (args) =>
    pendingRemoteSearch && pendingRemoteSearch.mode === 'keyword' && completeSongs(
      args[1],
      args[2].toUInt32(),
      args[3].toUInt32(),
      search,
    ));
  // 曲名検索結果だけを保留中の同モード要求へ渡します。
  replaceResult(catalog.title, 3, (args) =>
    pendingRemoteSearch && pendingRemoteSearch.mode === 'title' && completeSongs(
      args[1],
      args[2].toUInt32(),
      args[2].toUInt32(),
      catalog.title,
    ));
  // 歌手名検索結果だけを歌手行として保留中要求へ渡します。
  replaceResult(catalog.artist, 3, (args) =>
    pendingRemoteSearch && pendingRemoteSearch.mode === 'artist' && completeArtists(
      args[1],
      args[2].toUInt32(),
      args[2].toUInt32(),
    ));
  // 新曲一覧の先頭項目オフセットを補正して保留中要求へ渡します。
  replaceResult(catalog.new, 3, (args) =>
    pendingRemoteSearch && pendingRemoteSearch.mode === 'new' && completeSongs(
      args[1].add(parseInteger(catalog.new.firstItemOffset)),
      args[2].toUInt32(),
      args[2].toUInt32(),
      catalog.new,
    ));
  // ランキング一覧だけを保留中の同モード要求へ渡します。
  replaceResult(catalog.ranking, 4, (args) =>
    pendingRemoteSearch && pendingRemoteSearch.mode === 'ranking' && completeSongs(
      args[1],
      args[2].toUInt32(),
      args[3].toUInt32(),
      catalog.ranking,
    ));
  // DAM履歴を本体と同じコピー関数で展開し、リモコン結果へ変換します。
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
  // お気に入り要求だけ一覧ポインターを展開し、本体操作は元処理へ戻します。
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
  // リモコン履歴取得の失敗だけをAPIエラーへ変換します。
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
  // 一覧由来の曲詳細を、お気に入り・詳細表示・予約の保留目的へ振り分けます。
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
  // 一覧由来の曲詳細失敗を保留目的別に完了し、本体操作なら元処理へ戻します。
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
  // リモコン検索中だけ本体画面のローディング開始を抑止します。
  const searchStartReplacement = new NativeCallback(() => {
    if (pendingRemoteSearch) return;
    callOriginalSearchStart();
  }, 'void', []);
  Interceptor.replace(searchStartAddress, searchStartReplacement);
  retainedNativeCallbacks.push(searchStartReplacement);

  const searchErrorAddress = rva(search.errorUiRva);
  const callOriginalSearchError = new NativeFunction(searchErrorAddress, 'void', ['pointer']);
  // キーワード検索エラーをリモコンへ返し、本体操作時は元モーダルを維持します。
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
  // 一覧取得エラーをリモコンへ返し、本体操作時は元画面へ通知します。
  const catalogErrorReplacement = new NativeCallback((message, detail) => {
    if (finishSearchError('一覧を取得できませんでした')) return;
    callOriginalCatalogError(message, detail);
  }, 'void', ['pointer', 'int']);
  Interceptor.replace(catalogErrorAddress, catalogErrorReplacement);
  retainedNativeCallbacks.push(catalogErrorReplacement);

  // ClubDAM共通の開始通知はリモコン要求中だけ消費し、テレビ画面をローディングへ
  // 遷移させません。DAM本体からの操作では元コールバックを維持します。
  const reservationStartAddress = rva(reservation.startUiRva);
  const callOriginalReservationStart = new NativeFunction(reservationStartAddress, 'void', []);
  // 曲詳細・予約・お気に入り要求中だけ、本体UIへの開始通知を抑止します。
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
  // 検索由来の曲詳細を、表示・予約・お気に入りの保留目的へ振り分けます。
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
  // 検索由来の曲詳細失敗を保留目的別に完了し、本体操作なら元処理へ戻します。
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
  // リモコンから始めた登録成功だけをAPI結果へ変換します。
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
  // リモコンから始めた登録失敗だけをAPI結果へ変換します。
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
  // リモコンから始めた削除成功だけをAPI結果へ変換します。
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
  // リモコンから始めた削除失敗だけをAPI結果へ変換します。
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
