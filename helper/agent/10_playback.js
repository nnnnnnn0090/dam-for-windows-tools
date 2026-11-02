// Project: DAM for Windows Tools
// File: agent/10_playback.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

/** ネイティブポインターから上限付きUTF-8を読み、失敗時は空文字列を返します。 */
function safeUtf8(pointer, maximum = 8192) {
  if (!pointer || pointer.isNull()) return '';
  try {
    const value = pointer.readUtf8String(maximum) || '';
    const zero = value.indexOf('\u0000');
    return (zero >= 0 ? value.substring(0, zero) : value).trim();
  } catch (_) {
    try {
      return (pointer.readUtf8String() || '').trim();
    } catch (_) {
      return '';
    }
  }
}

/** ネイティブポインターから上限付きUTF-16を読み、失敗時は空文字列を返します。 */
function safeUtf16(pointer, maximum = 8192) {
  if (!pointer || pointer.isNull()) return '';
  try {
    const value = pointer.readUtf16String(maximum) || '';
    const zero = value.indexOf('\u0000');
    return (zero >= 0 ? value.substring(0, zero) : value).trim();
  } catch (_) {
    try {
      return (pointer.readUtf16String() || '').trim();
    } catch (_) {
      return '';
    }
  }
}

/** 外部値を「6184-92」形式の公開動画IDだけに制限します。 */
function cleanId(value) {
  const text = String(value == null ? '' : value).trim();
  return text.length <= 128 && /^[0-9A-Za-z]+-[0-9A-Za-z_-]+$/.test(text)
    ? text
    : '';
}

/** 表示文字列から制御文字と連続空白を除き、300文字以内だけを返します。 */
function cleanText(value) {
  if (typeof value !== 'string') return '';
  const cleaned = value
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return cleaned.length <= 300 ? cleaned : '';
}

/** C文字列を例外なく読み、指定上限までに切り詰めます。 */
function safeCString(pointer, maximum) {
  if (!pointer || pointer.isNull()) return '';
  try {
    const value = pointer.readUtf8String();
    return typeof value === 'string' ? value.slice(0, maximum) : '';
  } catch (_) {
    return '';
  }
}

/** Flutterとの要求相関IDを許可文字と長さで検証します。 */
function cleanCorrelationId(value) {
  const text = String(value == null ? '' : value);
  return /^[0-9A-Za-z_-]{8,128}$/.test(text) ? text : '';
}

/** DAM内部バッファ容量を超えない、制御文字なしの検索語だけを返します。 */
function cleanSearchQuery(value, capacity) {
  if (typeof value !== 'string') return '';
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
  return cleaned.length > 0 && cleaned.length < capacity ? cleaned : '';
}

/** ローカル二重処理を除外し、長さ制限内のHTTP(S)上流URLか判定します。 */
function validRemoteUrl(value) {
  return /^https?:\/\//i.test(value) && !LOCAL_SERVER.test(value) && value.length <= 8192;
}

/** 個別値を検証し、再生通知に使う安全な動画記述へまとめます。 */
function descriptorFrom(values) {
  return {
    videoId: cleanId(values.videoId),
    highUrl: validRemoteUrl(values.highUrl || '') ? values.highUrl : '',
    lowUrl: validRemoteUrl(values.lowUrl || '') ? values.lowUrl : '',
  };
}

/** highとlowのURLから公開動画IDを確定し、動画記述を生成します。 */
function resolveDescriptor(highUrl, lowUrl) {
  return descriptorFrom({
    videoId: extractVideoAssetId(highUrl) || extractVideoAssetId(lowUrl),
    highUrl,
    lowUrl,
  });
}

/** 現在再生中のDAMメモリから、確定動画IDに対応する曲情報だけを通知します。 */
function emitCurrentPlaybackMetadata(descriptor) {
  const metadata = DAM_TARGET_MANIFEST.hooks.currentPlaybackMetadata;
  try {
    if (rva(metadata.currentVideoIdRva).readU8() === 0) return;
    const maximum = parseInteger(metadata.capacityChars);
    const artist = cleanText(safeUtf16(rva(metadata.artistRva), maximum));
    const title = cleanText(safeUtf16(rva(metadata.titleRva), maximum));
    if (!artist && !title) return;
    if (!descriptor.videoId) return;
    send({
      type: 'metadata',
      candidates: [{ ids: [descriptor.videoId], artist, title }],
    });
  } catch (_) {
    // 読み取り専用の曲情報を取得できなくても、DAMの再生経路には影響させません。
  }
}
