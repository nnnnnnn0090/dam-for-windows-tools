// Project: DAM for Windows Tools
// File: agent/10_playback.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

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

function cleanId(value) {
  const text = String(value == null ? '' : value).trim();
  return text.length <= 128 && /^[0-9A-Za-z]+-[0-9A-Za-z_-]+$/.test(text)
    ? text
    : '';
}

function cleanText(value) {
  if (typeof value !== 'string') return '';
  const cleaned = value
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return cleaned.length <= 300 ? cleaned : '';
}

function safeCString(pointer, maximum) {
  if (!pointer || pointer.isNull()) return '';
  try {
    const value = pointer.readUtf8String();
    return typeof value === 'string' ? value.slice(0, maximum) : '';
  } catch (_) {
    return '';
  }
}

function cleanCorrelationId(value) {
  const text = String(value == null ? '' : value);
  return /^[0-9A-Za-z_-]{8,128}$/.test(text) ? text : '';
}

function cleanSearchQuery(value, capacity) {
  if (typeof value !== 'string') return '';
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
  return cleaned.length > 0 && cleaned.length < capacity ? cleaned : '';
}

function validRemoteUrl(value) {
  return /^https?:\/\//i.test(value) && !LOCAL_SERVER.test(value) && value.length <= 8192;
}

function descriptorFrom(values) {
  return {
    videoId: cleanId(values.videoId),
    highUrl: validRemoteUrl(values.highUrl || '') ? values.highUrl : '',
    lowUrl: validRemoteUrl(values.lowUrl || '') ? values.lowUrl : '',
  };
}

function resolveDescriptor(highUrl, lowUrl) {
  return descriptorFrom({
    videoId: extractVideoAssetId(highUrl) || extractVideoAssetId(lowUrl),
    highUrl,
    lowUrl,
  });
}

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
    // Playback must continue unchanged when read-only metadata is unavailable.
  }
}
