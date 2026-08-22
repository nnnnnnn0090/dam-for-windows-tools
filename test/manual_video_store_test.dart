// Project: DAM for Windows Tools
// File: manual_video_store_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:io';

import 'package:dam_for_windows_tools/infrastructure/app_paths.dart';
import 'package:dam_for_windows_tools/infrastructure/manual_video_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 差し替え動画の取り込み・変更・削除・別PC相当の復元を検証します。
void main() {
  test('manual videos are copied into portable data storage', () async {
    final root = await Directory.systemTemp.createTemp('dam-tools-videos-');
    final external = await Directory.systemTemp.createTemp('dam-tools-source-');
    try {
      final source = File(p.join(external.path, 'original.MP4'));
      await source.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
      final paths = AppPaths.forTesting(root: root);
      final store = ManualVideoStore(paths);

      final stored = await store.import('6184-92', source);

      expect(
        stored.path,
        p.join(paths.manualVideosDirectory.path, '6184-92.mp4'),
      );
      expect(await stored.readAsBytes(), <int>[1, 2, 3, 4]);
      expect(
        (await ManualVideoStore(paths).load())['6184-92']?.path,
        stored.path,
      );
    } finally {
      await root.delete(recursive: true);
      await external.delete(recursive: true);
    }
  });

  test('changing or clearing a manual video removes managed copies', () async {
    final root = await Directory.systemTemp.createTemp('dam-tools-videos-');
    final external = await Directory.systemTemp.createTemp('dam-tools-source-');
    try {
      final paths = AppPaths.forTesting(root: root);
      final store = ManualVideoStore(paths);
      final first = File(p.join(external.path, 'first.mp4'));
      final second = File(p.join(external.path, 'second.mkv'));
      await first.writeAsBytes(<int>[1]);
      await second.writeAsBytes(<int>[2]);

      final oldCopy = await store.import('6184-92', first);
      final newCopy = await store.import('6184-92', second);
      expect(await oldCopy.exists(), isFalse);
      expect(await newCopy.readAsBytes(), <int>[2]);

      await store.remove('6184-92');
      expect(await store.load(), isEmpty);
      expect(await newCopy.exists(), isFalse);
    } finally {
      await root.delete(recursive: true);
      await external.delete(recursive: true);
    }
  });

  test('copied data folder restores assignments under a new root', () async {
    final firstRoot = await Directory.systemTemp.createTemp('dam-tools-pc1-');
    final secondRoot = await Directory.systemTemp.createTemp('dam-tools-pc2-');
    final external = await Directory.systemTemp.createTemp('dam-tools-source-');
    try {
      final source = File(p.join(external.path, 'portable.webm'));
      await source.writeAsBytes(<int>[8, 6, 7, 5, 3, 0, 9]);
      final firstPaths = AppPaths.forTesting(root: firstRoot);
      final stored = await ManualVideoStore(firstPaths)
          .import('3246-51', source);

      final secondPaths = AppPaths.forTesting(root: secondRoot);
      await secondPaths.manualVideosDirectory.create(recursive: true);
      final moved = await stored.copy(
        p.join(secondPaths.manualVideosDirectory.path, p.basename(stored.path)),
      );
      final restored = await ManualVideoStore(secondPaths).load();

      expect(restored['3246-51']?.path, moved.path);
      expect(await restored['3246-51']!.readAsBytes(), <int>[
        8,
        6,
        7,
        5,
        3,
        0,
        9,
      ]);
    } finally {
      await firstRoot.delete(recursive: true);
      await secondRoot.delete(recursive: true);
      await external.delete(recursive: true);
    }
  });
}
