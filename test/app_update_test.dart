// Project: DAM for Windows Tools
// File: app_update_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:dam_for_windows_tools/application/app_controller.dart';
import 'package:dam_for_windows_tools/config/app_config.dart';
import 'package:dam_for_windows_tools/domain/app_update.dart';
import 'package:dam_for_windows_tools/infrastructure/release_update_service.dart';
import 'package:dam_for_windows_tools/presentation/home/app_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// バージョン比較とGitHubリリースの固定アセット選択を検証します。
void main() {
  test('compares semantic versions numerically', () {
    final current = AppVersion.tryParse('1.9.9');
    final latest = AppVersion.tryParse('v1.10.0');
    expect(current, isNotNull);
    expect(latest, isNotNull);
    expect(latest!.compareTo(current!), greaterThan(0));
    expect(AppVersion.tryParse('1.2'), isNull);
    expect(AppVersion.tryParse('1.2.3-beta'), isNull);
  });

  test('selects only the exact Windows archive asset', () {
    final update = ReleaseUpdateService.parseLatestRelease(<String, dynamic>{
      'tag_name': 'v1.2.0',
      'draft': false,
      'prerelease': false,
      'html_url': 'https://github.com/nnnnnnn0090/dam-for-windows-tools/releases/tag/v1.2.0',
      'body': '更新内容',
      'assets': <Map<String, Object>>[
        <String, Object>{
          'name': 'DAMforWindowsTools-1.2.0-win-x64.zip',
          'state': 'uploaded',
          'size': 1024,
          'browser_download_url': 'https://github.com/nnnnnnn0090/dam-for-windows-tools/releases/download/v1.2.0/DAMforWindowsTools-1.2.0-win-x64.zip',
        },
      ],
    }, currentVersion: '1.1.0');

    expect(update, isNotNull);
    expect(update!.version.toString(), '1.2.0');
    expect(update.archiveSize, 1024);
  });

  test('does not offer the current version again', () {
    final update = ReleaseUpdateService.parseLatestRelease(<String, dynamic>{
      'tag_name': '1.1.0',
      'draft': false,
      'prerelease': false,
    }, currentVersion: '1.1.0');
    expect(update, isNull);
  });

  test('rejects assets outside the official repository', () {
    expect(
      () => ReleaseUpdateService.parseLatestRelease(<String, dynamic>{
        'tag_name': '1.2.0',
        'draft': false,
        'prerelease': false,
        'assets': <Map<String, Object>>[
          <String, Object>{
            'name': 'DAMforWindowsTools-1.2.0-win-x64.zip',
            'size': 1024,
            'browser_download_url':
                'https://example.com/DAMforWindowsTools-1.2.0-win-x64.zip',
          },
        ],
      }, currentVersion: '1.1.0'),
      throwsFormatException,
    );
  });

  testWidgets('shows the current version and update action in the GUI', (
    tester,
  ) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(appBar: AppHeader(controller: controller)),
      ),
    );
    expect(find.text('v${AppConfig.productVersion}'), findsOneWidget);
    expect(find.byKey(const Key('update-button')), findsOneWidget);
  });
}
