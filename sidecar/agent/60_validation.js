// Project: DAM for Windows Tools
// File: agent/60_validation.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

/** フック・内部関数・パッチの全期待命令列を確認し、一致しなければ初期化を中止します。 */
function validateHooks() {
  verifyPrefix('playerSetFile', DAM_TARGET_MANIFEST.hooks.playerSetFile);
  verifyPrefix(
    'scoringDisplayStart',
    DAM_TARGET_MANIFEST.hooks.scoringDisplayStart,
  );
  verifyPrefix(
    'scoringDisplayStop',
    DAM_TARGET_MANIFEST.hooks.scoringDisplayStop,
  );
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
  const confirmation = DAM_TARGET_MANIFEST.hooks.messageConfirmation;
  verifyPrefix('messageConfirmationResponse', {
    rva: confirmation.respondRva,
    expectedPrefix: confirmation.respondExpectedPrefix,
  });
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
