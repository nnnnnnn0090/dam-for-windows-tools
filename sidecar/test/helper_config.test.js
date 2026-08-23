// Project: DAM for Windows Tools
// File: helper_config.test.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import assert from 'node:assert/strict';
import test from 'node:test';

import { normalizeConfig } from '../helper_config.js';

// 欠損設定が安全な有効初期値へ正規化されることを検証します。
test('normalizes helper configuration to secure enabled defaults', () => {
  assert.deepEqual(normalizeConfig(null), {
    disableModuleCheck: true,
    disableForegroundCheck: true,
    replaceVideoUrls: true,
    scoringOverlayEnabled: true,
    scoringShowZeroTechniques: true,
  });
  assert.deepEqual(normalizeConfig({ replaceVideoUrls: false }), {
    disableModuleCheck: true,
    disableForegroundCheck: true,
    replaceVideoUrls: false,
    scoringOverlayEnabled: true,
    scoringShowZeroTechniques: true,
  });
  assert.deepEqual(normalizeConfig({
    scoringOverlayEnabled: false,
    scoringShowZeroTechniques: false,
  }), {
    disableModuleCheck: true,
    disableForegroundCheck: true,
    replaceVideoUrls: true,
    scoringOverlayEnabled: false,
    scoringShowZeroTechniques: false,
  });
});
