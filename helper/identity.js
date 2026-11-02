// Project: DAM for Windows Tools
// File: identity.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

/** 公式HLS URLのファイル名から「6184-92」形式の公開動画IDだけを抽出します。 */
export function extractVideoAssetId(value) {
  const text = String(value == null ? '' : value).trim();
  if (!/^https?:\/\//i.test(text)) return '';
  const cleanUrl = text.split(/[?#]/, 1)[0];
  const fileName = cleanUrl.substring(cleanUrl.lastIndexOf('/') + 1);
  let match = fileName.match(
    /^([0-9A-Za-z]+-[0-9A-Za-z]+?)[A-Za-z]{2}_[0-9]+\.mp4\.m3u8$/i,
  );
  if (!match) {
    match = fileName.match(
      /^([0-9A-Za-z]+-[0-9A-Za-z_-]+)\.mp4\.m3u8$/i,
    );
  }
  return match ? match[1] : '';
}
