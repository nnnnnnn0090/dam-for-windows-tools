// Project: DAM for Windows Tools
// File: remote_page_provider.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'package:flutter/services.dart';

import '../config/app_config.dart';

class RemotePageProvider {
  Future<String>? _page;

  Future<String> load() => _page ??= _load();

  Future<String> _load() async {
    final template = await rootBundle.loadString(AppConfig.remotePageAsset);
    final page = template
        .replaceAll('{{PRODUCT_NAME}}', AppConfig.productName)
        .replaceAll('{{REMOTE_NAME}}', AppConfig.remoteName);
    if (page.contains('{{PRODUCT_NAME}}') || page.contains('{{REMOTE_NAME}}')) {
      throw StateError('リモコン画面のテンプレート展開に失敗しました');
    }
    return page;
  }
}
