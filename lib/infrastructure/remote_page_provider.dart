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
    final assets = await Future.wait<String>(<Future<String>>[
      rootBundle.loadString(AppConfig.remotePageAsset),
      rootBundle.loadString(AppConfig.remoteStyleAsset),
      rootBundle.loadString(AppConfig.remoteScriptAsset),
    ]);
    final template = assets[0];
    final page = template
        .replaceAll('{{REMOTE_STYLES}}', assets[1])
        .replaceAll('{{REMOTE_SCRIPT}}', assets[2])
        .replaceAll('{{PRODUCT_NAME}}', AppConfig.productName)
        .replaceAll('{{REMOTE_NAME}}', AppConfig.remoteName);
    if (RegExp(r'\{\{[A-Z_]+\}\}').hasMatch(page)) {
      throw StateError('リモコン画面のテンプレート展開に失敗しました');
    }
    return page;
  }
}
