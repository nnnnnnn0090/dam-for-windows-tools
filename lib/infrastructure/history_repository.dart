// Project: DAM for Windows Tools
// File: history_repository.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import '../domain/tracks.dart';
import 'app_paths.dart';
import 'json_file_store.dart';

class HistoryRepository {
  HistoryRepository(this.paths, [this._files = const JsonFileStore()]);

  static const int _maximumBytes = 2 * 1024 * 1024;
  static const int maximumRecords = 10000;

  final AppPaths paths;
  final JsonFileStore _files;

  Future<List<TrackRecord>> load() async {
    final decoded = await _files.read(
      paths.historyFile,
      maximumBytes: _maximumBytes,
    );
    if (decoded is! List) return <TrackRecord>[];

    final records = <TrackRecord>[];
    final seen = <String>{};
    for (final value in decoded) {
      if (records.length >= maximumRecords) break;
      if (value is! Map<String, dynamic>) continue;
      final record = TrackRecord.fromJson(value);
      if (record.videoId.isEmpty || !seen.add(record.videoId)) continue;
      records.add(record);
    }
    return records;
  }

  Future<void> save(Iterable<TrackRecord> records) => _files.write(
    paths.historyFile,
    records
        .take(maximumRecords)
        .map((record) => record.toJson())
        .toList(growable: false),
  );

  Future<void> clear() async {
    if (await paths.historyFile.exists()) await paths.historyFile.delete();
  }
}
