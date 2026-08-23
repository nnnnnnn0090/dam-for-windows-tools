// Project: DAM for Windows Tools
// File: helper_config.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

/** 欠損や型違いを安全な初期値へ戻し、Agentへ渡す機能設定だけを抽出します。 */
export function normalizeConfig(value) {
  const source = value && typeof value === 'object' ? value : {};
  return {
    disableModuleCheck: source.disableModuleCheck !== false,
    disableForegroundCheck: source.disableForegroundCheck !== false,
    replaceVideoUrls: source.replaceVideoUrls !== false,
    scoringOverlayEnabled:
      source.scoringOverlayEnabled !== false && source.scoringEnabled !== false,
    scoringShowZeroTechniques: source.scoringShowZeroTechniques !== false,
  };
}
