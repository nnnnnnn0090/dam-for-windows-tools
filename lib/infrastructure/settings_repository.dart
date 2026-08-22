// Project: DAM for Windows Tools
// File: settings_repository.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import '../domain/app_settings.dart';
import 'app_paths.dart';
import 'json_file_store.dart';

class SettingsRepository {
  SettingsRepository(this.paths, [this._files = const JsonFileStore()]);

  static const int _maximumBytes = 64 * 1024;

  final AppPaths paths;
  final JsonFileStore _files;

  Future<AppSettings> load() async {
    final decoded = await _files.read(
      paths.settingsFile,
      maximumBytes: _maximumBytes,
    );
    return decoded is Map<String, dynamic>
        ? AppSettings.fromJson(decoded)
        : const AppSettings();
  }

  Future<void> save(AppSettings settings) =>
      _files.write(paths.settingsFile, settings.normalized().toJson());
}
