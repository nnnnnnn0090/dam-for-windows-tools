// Project: DAM for Windows Tools
// File: main.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'application/app_controller.dart';
import 'config/app_config.dart';
import 'config/app_license_registry.dart';
import 'infrastructure/app_paths.dart';
import 'presentation/home_page.dart';

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

class DamForWindowsToolsApp extends StatefulWidget {
  const DamForWindowsToolsApp({super.key, required this.singleInstanceGuard});

  final SingleInstanceGuard? singleInstanceGuard;

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
    if (widget.singleInstanceGuard != null) {
      unawaited(controller.initialize());
    }
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
    widget.singleInstanceGuard?.release();
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
      darkTheme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xff5b9bd5),
          onPrimary: Colors.white,
          secondary: Color(0xff5b9bd5),
          surface: Color(0xff171a1f),
          error: Color(0xffd96767),
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xff111318),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xff191c21),
          foregroundColor: Color(0xffe5e7ea),
          elevation: 0,
          scrolledUnderElevation: 0,
          shape: Border(bottom: BorderSide(color: Color(0xff333840))),
        ),
        cardTheme: const CardThemeData(
          color: Color(0xff171a1f),
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
            side: BorderSide(color: Color(0xff333840)),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xff333840),
          thickness: 1,
          space: 1,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xff111318),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(3)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(3)),
            borderSide: BorderSide(color: Color(0xff454b55)),
          ),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        ),
        textButtonTheme: const TextButtonThemeData(
          style: ButtonStyle(
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(3)),
              ),
            ),
          ),
        ),
        tooltipTheme: const TooltipThemeData(
          waitDuration: Duration(milliseconds: 350),
        ),
      ),
      home: HomePage(controller: controller),
    );
  }
}
