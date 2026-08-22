// Project: DAM for Windows Tools
// File: identity.test.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import assert from 'node:assert/strict';
import test from 'node:test';

import { extractVideoAssetId } from '../identity.js';

test('extracts the public video asset ID without using numeric DAM IDs', () => {
  assert.equal(
    extractVideoAssetId('https://example.invalid/hls/6184-92HD_1500.mp4.m3u8?token=x'),
    '6184-92',
  );
  assert.equal(
    extractVideoAssetId('https://example.invalid/hls/6184-92.mp4.m3u8'),
    '6184-92',
  );
});

test('rejects non-HLS and non-HTTP identities', () => {
  assert.equal(extractVideoAssetId('6184-92'), '');
  assert.equal(extractVideoAssetId('file:///6184-92.mp4.m3u8'), '');
  assert.equal(extractVideoAssetId('https://example.invalid/5785365.m3u8'), '');
});
