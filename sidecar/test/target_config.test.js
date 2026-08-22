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
