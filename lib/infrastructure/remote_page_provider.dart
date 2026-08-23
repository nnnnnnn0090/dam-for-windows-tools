// Project: DAM for Windows Tools
// File: remote_page_provider.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'package:flutter/services.dart';

import '../config/app_config.dart';

/// HTML・CSS・JavaScriptアセットを、外部依存のない1枚のWeb画面へ展開します。
class RemotePageProvider {
  Future<String>? _page;

  /// 初回だけアセットを読み込み、以後の要求では同じ完成ページを再利用します。
  Future<String> load() => _page ??= _load();

  /// テンプレート変数をすべて置換し、未展開変数が残れば起動を失敗させます。
  Future<String> _load() async {
    final assets = await Future.wait<String>(<Future<String>>[
      rootBundle.loadString(AppConfig.remotePageAsset),
      rootBundle.loadString(AppConfig.remoteStyleAsset),
      rootBundle.loadString(AppConfig.remoteScriptAsset),
      rootBundle.loadString(AppConfig.remoteIconAsset),
    ]);
    final template = assets[0];
    final page = template
        .replaceAll('{{REMOTE_STYLES}}', assets[1])
        .replaceAll('{{REMOTE_SCRIPT}}', assets[2])
        .replaceAll('{{REMOTE_ICONS}}', assets[3])
        .replaceAll('{{PRODUCT_NAME}}', AppConfig.productName)
        .replaceAll('{{PRODUCT_VERSION}}', AppConfig.productVersion)
        .replaceAll('{{REMOTE_NAME}}', AppConfig.remoteName);
    if (RegExp(r'\{\{[A-Z_]+\}\}').hasMatch(page)) {
      throw StateError('リモコン画面のテンプレート展開に失敗しました');
    }
    return page;
  }
}
