// Project: DAM for Windows Tools
// File: storage.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:convert';
import 'dart:io';

import '../domain/models.dart';
import 'app_paths.dart';
import 'atomic_file.dart';

class AppStorage {
  AppStorage(this.paths);

  static const int _maximumSettingsBytes = 64 * 1024;
  static const int _maximumHistoryBytes = 2 * 1024 * 1024;
  static const int _maximumHistoryRecords = 10000;
  final AppPaths paths;

  Future<AppSettings> loadSettings() async {
    final file = paths.settingsFile;
    if (!await file.exists()) return const AppSettings();
    try {
      if (await file.length() > _maximumSettingsBytes) {
        return const AppSettings();
      }
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic>
          ? AppSettings.fromJson(decoded)
          : const AppSettings();
    } on Object {
      return const AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings settings) =>
      _writeJsonAtomically(paths.settingsFile, settings.toJson());

  Future<List<TrackRecord>> loadHistory() async {
    final file = paths.historyFile;
    if (!await file.exists()) return <TrackRecord>[];
    try {
      if (await file.length() > _maximumHistoryBytes) {
        return <TrackRecord>[];
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return <TrackRecord>[];
      final records = <TrackRecord>[];
      final seen = <String>{};
      for (final value in decoded) {
        if (records.length >= _maximumHistoryRecords) break;
        if (value is! Map<String, dynamic>) continue;
        final record = TrackRecord.fromJson(value);
        if (record.videoId.isEmpty || !seen.add(record.videoId)) continue;
        records.add(record);
      }
      return records;
    } on Object {
      return <TrackRecord>[];
    }
  }

  Future<void> saveHistory(Iterable<TrackRecord> records) {
    return _writeJsonAtomically(
      paths.historyFile,
      records
          .take(_maximumHistoryRecords)
          .map((record) => record.toJson())
          .toList(growable: false),
    );
  }

  Future<void> clearHistory() async {
    if (await paths.historyFile.exists()) {
      await paths.historyFile.delete();
    }
  }

  Future<void> _writeJsonAtomically(File destination, Object value) async {
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsString(prettyJson(value), flush: true);
    await replaceFileAtomically(temporary, destination);
  }
}
