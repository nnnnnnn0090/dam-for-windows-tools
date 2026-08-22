// Project: DAM for Windows Tools
// File: history_repository.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import '../domain/tracks.dart';
import 'app_paths.dart';
import 'json_file_store.dart';

/// 権利上保存可能な3項目だけを、上限付きJSON履歴として永続化します。
class HistoryRepository {
  /// 保存先と、テストで差し替え可能なJSON入出力実装を受け取ります。
  HistoryRepository(this.paths, [this._files = const JsonFileStore()]);

  static const int _maximumBytes = 2 * 1024 * 1024;
  static const int maximumRecords = 10000;

  final AppPaths paths;
  final JsonFileStore _files;

  /// サイズ・件数・動画ID重複を検証しながら保存済み履歴を読み込みます。
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

  /// 最大件数までの履歴を、URLやファイルパスを含めず原子的に保存します。
  Future<void> save(Iterable<TrackRecord> records) => _files.write(
    paths.historyFile,
    records
        .take(maximumRecords)
        .map((record) => record.toJson())
        .toList(growable: false),
  );

  /// 履歴ファイルだけを削除し、設定と差し替え動画は保持します。
  Future<void> clear() async {
    if (await paths.historyFile.exists()) await paths.historyFile.delete();
  }
}
