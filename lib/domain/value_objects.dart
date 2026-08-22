// Project: DAM for Windows Tools
// File: value_objects.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

final RegExp _videoAssetIdPattern = RegExp(r'^[0-9A-Za-z]+-[0-9A-Za-z_-]+$');

String normalizeVideoAssetId(Object? value) {
  if (value is! String) return '';
  final text = value.trim();
  return text.length <= 128 && _videoAssetIdPattern.hasMatch(text) ? text : '';
}

String sanitizeText(Object? value, {required int maximumLength}) {
  if (value is! String) return '';
  final cleaned = value
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.length <= maximumLength
      ? cleaned
      : cleaned.substring(0, maximumLength);
}

Uri? parseHttpUri(Object? value, {int maximumLength = 8192}) {
  if (value is! String || value.length > maximumLength) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return uri;
}
