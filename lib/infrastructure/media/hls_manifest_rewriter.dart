// Project: DAM for Windows Tools
// File: media/hls_manifest_rewriter.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'media_job.dart';

class HlsManifestRewriter {
  const HlsManifestRewriter({required this.sessionToken});

  final String sessionToken;

  String rewrite(MediaJob job, Uri baseUri, String source) {
    String localize(String raw) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed.length > 8192) return raw;
      final resolved = baseUri.resolve(trimmed);
      if (resolved.scheme != 'http' && resolved.scheme != 'https') return raw;
      final id = sha256
          .convert(utf8.encode(resolved.toString()))
          .toString()
          .substring(0, 32);
      job.proxyAssets[id] = resolved;
      return '/v1/$sessionToken/${job.id}/proxy/$id';
    }

    final uriAttribute = RegExp(r'URI="([^"]+)"');
    return source
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) {
          if (line.isEmpty) return line;
          if (!line.startsWith('#')) return localize(line);
          return line.replaceAllMapped(uriAttribute, (match) {
            return 'URI="${localize(match.group(1)!)}"';
          });
        })
        .join('\n');
  }
}
