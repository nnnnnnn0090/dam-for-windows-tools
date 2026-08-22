// Project: DAM for Windows Tools
// File: settings_repository.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import '../domain/app_settings.dart';
import 'app_paths.dart';
import 'json_file_store.dart';

/// GUI設定をサイズ制限付きJSONとして読み書きします。
class SettingsRepository {
  /// 保存先と、テストで差し替え可能なJSON入出力実装を受け取ります。
  SettingsRepository(this.paths, [this._files = const JsonFileStore()]);

  static const int _maximumBytes = 64 * 1024;

  final AppPaths paths;
  final JsonFileStore _files;

  /// 保存値を読み込み、欠損・破損時は安全な初期設定を返します。
  Future<AppSettings> load() async {
    final decoded = await _files.read(
      paths.settingsFile,
      maximumBytes: _maximumBytes,
    );
    return decoded is Map<String, dynamic>
        ? AppSettings.fromJson(decoded)
        : const AppSettings();
  }

  /// 範囲外値を正規化してから設定ファイルを原子的に更新します。
  Future<void> save(AppSettings settings) =>
      _files.write(paths.settingsFile, settings.normalized().toJson());
}
