// Project: DAM for Windows Tools
// File: storage_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:io';

import 'package:dam_for_windows_tools/domain/app_settings.dart';
import 'package:dam_for_windows_tools/domain/tracks.dart';
import 'package:dam_for_windows_tools/infrastructure/app_paths.dart';
import 'package:dam_for_windows_tools/infrastructure/history_repository.dart';
import 'package:dam_for_windows_tools/infrastructure/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// 履歴重複除去と、履歴消去が設定へ影響しないことを検証します。
void main() {
  test('history storage de-duplicates IDs and clears only history', () async {
    final root = await Directory.systemTemp.createTemp('dam-tools-storage-');
    try {
      final paths = AppPaths.forTesting(root: root);
      final settings = SettingsRepository(paths);
      final historyRepository = HistoryRepository(paths);
      await settings.save(const AppSettings(skipMs: 150));
      await historyRepository.save(const <TrackRecord>[
        TrackRecord(videoId: '6184-92', artist: 'A', title: 'T'),
        TrackRecord(videoId: '6184-92', artist: 'B', title: 'U'),
      ]);

      final history = await historyRepository.load();
      expect(history, hasLength(1));
      expect(history.single.videoId, '6184-92');

      await historyRepository.clear();
      expect(await paths.historyFile.exists(), isFalse);
      expect(await paths.settingsFile.exists(), isTrue);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
