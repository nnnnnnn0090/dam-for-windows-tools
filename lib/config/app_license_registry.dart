// Project: DAM for Windows Tools
// File: app_license_registry.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Flutter標準のライセンス画面へ、本体と同梱物の通知文を登録します。
abstract final class AppLicenseRegistry {
  static bool _registered = false;

  /// アプリのライセンス、第三者通知、非公式表示を起動中に1回だけ登録します。
  static void register() {
    if (_registered) return;
    _registered = true;

    _addAsset(const <String>[
      'DAM for Windows Tools',
      'FFmpeg 9.0.1 Gyan full build',
    ], 'LICENSE');
    _addAssets(
      const <String>['Frida Node bindings'],
      const <String>[
        'legal/Frida-LGPL-2.0.txt',
        'legal/WxWindows-exception-3.1.txt',
      ],
    );
    _addAsset(const <String>[
      'QRCode for JavaScript algorithm',
    ], 'legal/QR-Code-generator-MIT.txt');
    _addAsset(const <String>['Lucide Icons 1.33.0'], 'legal/Lucide-ISC.txt');
    _addAsset(const <String>['Node.js runtime'], 'legal/Node.js.txt');
    _addAsset(const <String>[
      'Microsoft Visual C++ Runtime',
    ], 'legal/Microsoft-Visual-Cpp-Runtime.txt');
    _addAsset(const <String>[
      'DAM for Windows Tools — third-party notices',
    ], 'THIRD_PARTY_NOTICES.md');
    _addAsset(const <String>[
      'DAM for Windows Tools — 非公式ツールに関する表示',
    ], 'LEGAL_NOTICE.md');
  }

  /// 1つの同梱文書を、指定した製品名のライセンス項目として遅延読み込みします。
  static void _addAsset(List<String> packages, String asset) {
    LicenseRegistry.addLicense(() async* {
      final text = await rootBundle.loadString(asset);
      yield LicenseEntryWithLineBreaks(packages, text);
    });
  }

  /// 複数文書で構成されるライセンスを、1項目へ連結して登録します。
  static void _addAssets(List<String> packages, List<String> assets) {
    LicenseRegistry.addLicense(() async* {
      final sections = await Future.wait(assets.map(rootBundle.loadString));
      yield LicenseEntryWithLineBreaks(packages, sections.join('\n\n'));
    });
  }
}
