// Project: DAM for Windows Tools
// File: hls_manifest_rewriter_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:io';

import 'package:dam_for_windows_tools/infrastructure/media/hls_manifest_rewriter.dart';
import 'package:dam_for_windows_tools/infrastructure/media/media_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'rewrites HLS media, variant, and key URIs into opaque local routes',
    () {
      const token = 'session-token';
      final job = MediaJob(
        id: 'job-id',
        videoId: '6184-92',
        highUrl: null,
        lowUrl: null,
        manualSource: null,
        skipMs: 0,
        outputDirectory: Directory.systemTemp,
      );
      const source =
          '#EXTM3U\r\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin"\r\n'
          'segment-1.ts\r\n'
          'data:text/plain,unchanged\r\n';
      final output = const HlsManifestRewriter(
        sessionToken: token,
      ).rewrite(job, Uri.parse('https://media.example/hls/index.m3u8'), source);

      expect(output, contains('/v1/$token/job-id/proxy/'));
      expect(output, contains('data:text/plain,unchanged'));
      expect(job.proxyAssets, hasLength(2));
      expect(
        job.proxyAssets.values,
        contains(Uri.parse('https://media.example/hls/segment-1.ts')),
      );
      expect(
        job.proxyAssets.values,
        contains(Uri.parse('https://media.example/hls/keys/key.bin')),
      );
    },
  );
}
