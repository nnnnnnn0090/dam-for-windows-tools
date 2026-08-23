// Project: DAM for Windows Tools
// File: agent_source.test.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

import { agentFragmentNames, composeAgentSource } from '../agent_source.js';

// Agent結合後にES Module構文が残らず、Fridaの古典スクリプトとして解析できることを検証します。
test('composes a classic Frida script without ES module exports', () => {
  const fragmentDirectory = new URL('../agent/', import.meta.url);
  const actualFragmentNames = fs
    .readdirSync(fragmentDirectory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.js'))
    .map((entry) => entry.name)
    .sort();
  assert.deepEqual(actualFragmentNames, [...agentFragmentNames].sort());

  const identitySource = fs.readFileSync(
    new URL('../identity.js', import.meta.url),
    'utf8',
  );
  const agentSources = agentFragmentNames.map((filename) =>
    fs.readFileSync(new URL(`../agent/${filename}`, import.meta.url), 'utf8'),
  );
  const source = composeAgentSource({
    manifest: { target: { processName: 'DKKaraokeWindows.exe' } },
    runtimeConfig: { mediaOrigin: 'http://127.0.0.1:8765' },
    identitySource,
    agentSources,
  });

  assert.doesNotMatch(source, /^(?:\s*)export\s/m);
  assert.doesNotThrow(() => new Function(source));
  assert.match(source, /function extractVideoAssetId\(value\)/);
  assert.match(source, /function installDamScoringOverlay\(\)/);
});

// 追加グリッドの寿命がCRIエンジンではなく、本体の歌唱表現表示に同期することを固定します。
test('scoring overlay follows the native singing-technique display lifecycle', () => {
  const manifest = JSON.parse(fs.readFileSync(
    new URL('../supported-dam.json', import.meta.url),
    'utf8',
  ));
  const scoringSource = fs.readFileSync(
    new URL('../agent/30_scoring.js', import.meta.url),
    'utf8',
  );

  assert.deepEqual(manifest.hooks.scoringDisplayStart, {
    rva: '0x0be5bb',
    expectedPrefix: 'c605a56a490200',
    activeStateRva: '0x2555067',
    activeValue: 0,
    meaning: 'native singing-technique display becomes active after the scoring scene has finished initializing',
  });
  assert.deepEqual(manifest.hooks.scoringDisplayStop, {
    rva: '0x0be746',
    expectedPrefix: 'c6051a69490201',
    activeStateRva: '0x2555067',
    inactiveValue: 1,
    meaning: 'native singing-technique display becomes inactive immediately after scoring finalization',
  });
  assert.match(scoringSource, /hooks\.scoringDisplayStart/);
  assert.match(scoringSource, /hooks\.scoringDisplayStop/);
  assert.match(scoringSource, /hooks\.scoringStop/);
  assert.match(scoringSource, /playback\.pauseRva/);
  assert.match(scoringSource, /playback\.stopRva/);
  assert.doesNotMatch(scoringSource, /hooks\.scoringStart/);
});

// Agent自身から呼ぶ停止・一時停止でも、Interceptorの再入通知に依存せず表示が同期することを固定します。
test('remote playback controls explicitly synchronize the scoring overlay', () => {
  const playbackSource = fs.readFileSync(
    new URL('../agent/20_remote_playback.js', import.meta.url),
    'utf8',
  );

  const stopStart = playbackSource.indexOf("action === 'stop'");
  const stopEnd = playbackSource.indexOf("action === 'restart'", stopStart);
  const stopBranch = playbackSource.substring(stopStart, stopEnd);
  assert.notEqual(stopStart, -1);
  assert.notEqual(stopEnd, -1);
  assert.match(stopBranch, /stop\(\);/);
  assert.match(stopBranch, /finishScoringSession\(\);/);
  assert.match(
    playbackSource,
    /setPause\([\s\S]*?scoringPauseActive = requestedPause;[\s\S]*?hideDamScoringOverlay\(\)/,
  );
});

// DAM履歴が検証済み一覧経路と曲詳細経路を使用することを検証します。
test('DAM play history uses its verified catalog and list-detail path', () => {
  const manifest = JSON.parse(fs.readFileSync(
    new URL('../supported-dam.json', import.meta.url),
    'utf8',
  ));
  const history = manifest.hooks.remoteCatalog.history;

  assert.deepEqual({
    entryRva: history.entryRva,
    resultRva: history.resultRva,
    copyListRva: history.copyListRva,
    errorRva: history.errorRva,
    recordStride: history.recordStride,
    artistOffset: history.artistOffset,
    titleOffset: history.titleOffset,
    listMode: history.listMode,
    remoteOnlyPreludePatches: history.remoteOnlyPreludePatches,
  }, {
    entryRva: '0x0fb160',
    resultRva: '0x0fb4b0',
    copyListRva: '0x0f9770',
    errorRva: '0x105970',
    recordStride: '0x690',
    artistOffset: '0x4',
    titleOffset: '0x310',
    listMode: 2,
    remoteOnlyPreludePatches: [
      {
        rva: '0x0fb1a3',
        expectedBytes: 'e830301600',
        replacementBytes: '9090909090',
      },
      {
        rva: '0x0fb1af',
        expectedBytes: 'e810371600',
        replacementBytes: '9090909090',
      },
    ],
  });
});

// UI操作がメッセージ取得中へ再入せず、WndProc完了後にだけ実行されることを固定します。
test('dispatches DAM UI work only after its private window message', () => {
  const runtime = fs.readFileSync(
    new URL('../agent/00_runtime.js', import.meta.url),
    'utf8',
  );

  assert.match(runtime, /RegisterWindowMessageW/);
  assert.match(runtime, /DispatchMessageW/);
  assert.match(runtime, /PostMessageW/);
  assert.doesNotMatch(runtime, /PeekMessageW|GetMessageW|PostThreadMessageW/);
});

// 確認画面の読み取りと応答が解析済みMessageArea経路だけを参照することを検証します。
test('describes the verified MessageArea yes-no response path', () => {
  const manifest = JSON.parse(fs.readFileSync(
    new URL('../supported-dam.json', import.meta.url),
    'utf8',
  ));
  const confirmation = manifest.hooks.messageConfirmation;

  assert.deepEqual({
    sceneStateRva: confirmation.sceneStateRva,
    selectionRva: confirmation.selectionRva,
    messageRva: confirmation.messageRva,
    buttonModeRva: confirmation.buttonModeRva,
    respondRva: confirmation.respondRva,
    yesSelection: confirmation.yesSelection,
    noSelection: confirmation.noSelection,
  }, {
    sceneStateRva: '0x256bc70',
    selectionRva: '0x256bd70',
    messageRva: '0x256bd80',
    buttonModeRva: '0x256bce4',
    respondRva: '0x0c2330',
    yesSelection: 0,
    noSelection: 1,
  });
});
