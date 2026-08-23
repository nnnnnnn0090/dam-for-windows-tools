// Project: DAM for Windows Tools
// File: target_config.test.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  loadTargetConfiguration,
  normalizeMediaOrigin,
  resolveScoringOverlay,
  targetManifestFilename,
} from '../target_config.js';

// 配信Originが認証情報なしのHTTPループバックだけに制限されることを検証します。
test('accepts only an unauthenticated loopback HTTP origin', () => {
  assert.equal(normalizeMediaOrigin('http://127.0.0.1:8765'), 'http://127.0.0.1:8765');
  for (const value of [
    'https://127.0.0.1:8765',
    'http://localhost:8765',
    'http://127.0.0.1:8765/path',
    'http://user:pass@127.0.0.1:8765',
  ]) {
    assert.throws(() => normalizeMediaOrigin(value));
  }
});

// 配布版のDLLとFlutter内アイコンを、利用者データではなくアプリルートから解決します。
test('resolves the packaged native scoring overlay from the application root', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dam-tools-overlay-'));
  try {
    const helper = path.join(root, 'runtime', 'helper');
    const assets = path.join(root, 'data', 'flutter_assets', 'assets', 'scoring');
    fs.mkdirSync(helper, { recursive: true });
    fs.mkdirSync(assets, { recursive: true });
    fs.writeFileSync(path.join(root, 'dam_scoring_overlay_1_1_4.dll'), 'fixture');
    fs.writeFileSync(path.join(root, 'dam_scoring_overlay.dll'), 'old fixture');
    const resolved = resolveScoringOverlay(helper, root, '1.1.4');
    assert.equal(resolved.libraryPath,
      path.join(root, 'dam_scoring_overlay_1_1_4.dll'));
    assert.equal(resolved.assetDirectory, assets);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// 対応マニフェストのプロセス名・版・SHA-256が厳密に検証されることを確認します。
test('validates the exact target manifest identity', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dam-tools-target-'));
  const previousOrigin = process.env.DAM_TOOLS_MEDIA_ORIGIN;
  try {
    fs.writeFileSync(
      path.join(directory, targetManifestFilename),
      JSON.stringify({
        target: {
          processName: 'DKKaraokeWindows.exe',
          fileVersion: '1.1.7.0',
          sha256: 'c47e25af4d5b96d299c17dfcce464b5e84c5cce0f81b3080ce7e5beb37839099',
        },
      }),
    );
    process.env.DAM_TOOLS_MEDIA_ORIGIN = 'http://127.0.0.1:8765';
    const configuration = loadTargetConfiguration(directory);
    assert.equal(configuration.processName, 'DKKaraokeWindows.exe');
    assert.equal(configuration.targetLabel, 'DAM for Windows 1.1.7.0');
  } finally {
    if (previousOrigin === undefined) delete process.env.DAM_TOOLS_MEDIA_ORIGIN;
    else process.env.DAM_TOOLS_MEDIA_ORIGIN = previousOrigin;
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
