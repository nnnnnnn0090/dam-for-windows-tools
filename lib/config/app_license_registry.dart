// Project: DAM for Windows Tools
// File: app_license_registry.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class AppLicenseRegistry {
  static bool _registered = false;

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

  static void _addAsset(List<String> packages, String asset) {
    LicenseRegistry.addLicense(() async* {
      final text = await rootBundle.loadString(asset);
      yield LicenseEntryWithLineBreaks(packages, text);
    });
  }

  static void _addAssets(List<String> packages, List<String> assets) {
    LicenseRegistry.addLicense(() async* {
      final sections = await Future.wait(assets.map(rootBundle.loadString));
      yield LicenseEntryWithLineBreaks(packages, sections.join('\n\n'));
    });
  }
}
