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

/// アプリ全体のテーマと、Windows終了要求を扱う最上位Widgetです。
class DamForWindowsToolsApp extends StatefulWidget {
  /// 単一起動Mutexの所有権を、Widgetの生存期間と結び付けて生成します。
  const DamForWindowsToolsApp({super.key, required this.singleInstanceGuard});

  final SingleInstanceGuard singleInstanceGuard;

  /// ネイティブ終了処理を管理する状態を生成します。
  @override
  State<DamForWindowsToolsApp> createState() => _DamForWindowsToolsAppState();
}

/// サービス初期化と、パッチ復元を待ってから閉じる終了手順を管理します。
class _DamForWindowsToolsAppState extends State<DamForWindowsToolsApp>
    with WidgetsBindingObserver {
  static const MethodChannel _lifecycleChannel = MethodChannel(
    AppConfig.lifecycleChannel,
  );

  late final AppController controller = AppController();
  bool _nativeCloseHandled = false;

  /// ライフサイクル監視を登録し、GUIを表示したままバックグラウンド初期化を開始します。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycleChannel.setMethodCallHandler(_handleLifecycleMethod);
    unawaited(controller.initialize());
  }

  /// Flutterエンジン切断時にもサービス終了を開始し、パッチを残さないようにします。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(controller.shutdown());
    }
  }

  /// コールバック、サービス、コントローラー、Mutexを登録と逆の順で解放します。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lifecycleChannel.setMethodCallHandler(null);
    unawaited(controller.shutdown());
    controller.dispose();
    widget.singleInstanceGuard.release();
    super.dispose();
  }

  /// Windowsの閉じる要求を一度だけ処理し、清掃完了後にネイティブ側へ許可を返します。
  Future<void> _handleLifecycleMethod(MethodCall call) async {
    if (call.method != 'closeRequested' || _nativeCloseHandled) return;
    _nativeCloseHandled = true;
    await controller.shutdown();
    await _lifecycleChannel.invokeMethod<void>('closeReady');
  }

  /// 製品テーマと状態監視済みホーム画面を構築します。
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
