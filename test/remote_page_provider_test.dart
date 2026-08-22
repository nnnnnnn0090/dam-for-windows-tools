// Project: DAM for Windows Tools
// File: remote_page_provider_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:dam_for_windows_tools/config/app_config.dart';
import 'package:dam_for_windows_tools/infrastructure/remote_page_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// リモコンHTML・CSS・JavaScriptの一体化とキャッシュを検証します。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('assembles the remote HTML, CSS, and script assets once', () async {
    final provider = RemotePageProvider();
    final first = await provider.load();
    final second = await provider.load();
    expect(identical(first, second), isTrue);
    expect(first, contains(AppConfig.productName));
    expect(first, contains('async function api('));
    expect(first, contains('--panel:#171c24'));
    expect(first, contains('id="damConfirmation"'));
    expect(first, contains("action:yes?'confirmYes':'confirmNo'"));
    expect(first, isNot(contains('{{REMOTE_')));
  });
}
