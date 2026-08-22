// Project: DAM for Windows Tools
// File: app.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/app_controller.dart';
import '../config/app_config.dart';
import '../config/app_theme.dart';
import '../infrastructure/windows_single_instance.dart';
import 'home/home_page.dart';

class DamForWindowsToolsApp extends StatefulWidget {
  const DamForWindowsToolsApp({super.key, required this.singleInstanceGuard});

  final SingleInstanceGuard singleInstanceGuard;

  @override
  State<DamForWindowsToolsApp> createState() => _DamForWindowsToolsAppState();
}

class _DamForWindowsToolsAppState extends State<DamForWindowsToolsApp>
    with WidgetsBindingObserver {
  static const MethodChannel _lifecycleChannel = MethodChannel(
    AppConfig.lifecycleChannel,
  );

  late final AppController controller = AppController();
  bool _nativeCloseHandled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycleChannel.setMethodCallHandler(_handleLifecycleMethod);
    unawaited(controller.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(controller.shutdown());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lifecycleChannel.setMethodCallHandler(null);
    unawaited(controller.shutdown());
    controller.dispose();
    widget.singleInstanceGuard.release();
    super.dispose();
  }

  Future<void> _handleLifecycleMethod(MethodCall call) async {
    if (call.method != 'closeRequested' || _nativeCloseHandled) return;
    _nativeCloseHandled = true;
    await controller.shutdown();
    await _lifecycleChannel.invokeMethod<void>('closeReady');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.productName,
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: AppTheme.dark,
      home: HomePage(controller: controller),
    );
  }
}
