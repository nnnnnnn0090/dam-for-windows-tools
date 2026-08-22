// Project: DAM for Windows Tools
// File: main.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:io';

import 'package:flutter/material.dart';

import 'config/app_license_registry.dart';
import 'infrastructure/windows_single_instance.dart';
import 'presentation/app.dart';

/// ライセンスを登録し、単一起動を確認してからFlutter GUIを開始します。
///
/// 二重起動時は新しいプロセスを残さず、既存ウィンドウだけを前面へ戻します。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLicenseRegistry.register();
  final guard = SingleInstanceGuard.acquire();
  if (guard == null) {
    SingleInstanceGuard.activateExistingWindow();
    exit(0);
  }
  runApp(DamForWindowsToolsApp(singleInstanceGuard: guard));
}
