// Project: DAM for Windows Tools
// File: home/home_page.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';

import '../../application/app_controller.dart';
import 'app_header.dart';
import 'fatal_error_view.dart';
import 'page_tabs.dart';
import 'scoring_page.dart';
import 'video_page.dart';

/// 接続状態ヘッダーと、動画・採点の主要画面をまとめるホーム画面です。
class HomePage extends StatefulWidget {
  /// アプリ状態を公開するコントローラーを受け取ります。
  const HomePage({super.key, required this.controller});

  final AppController controller;

  /// 選択中タブを保持する状態を生成します。
  @override
  State<HomePage> createState() => _HomePageState();
}

/// タブ選択を保持し、コントローラー変更時に表示内容だけを再構築します。
class _HomePageState extends State<HomePage> {
  int _selectedPage = 0;

  /// 致命エラーの有無に応じて、通常画面または復旧案内を表示します。
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return Scaffold(
          appBar: AppHeader(controller: controller),
          body: controller.fatalError == null
              ? _workspace(controller)
              : FatalErrorView(error: controller.fatalError!),
        );
      },
    );
  }

  /// タブと、選択された動画・採点ページを組み立てます。
  Widget _workspace(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PageTabs(
          selectedIndex: _selectedPage,
          onSelected: (index) => setState(() => _selectedPage = index),
        ),
        Expanded(
          child: _selectedPage == 0
              ? VideoPage(controller: controller)
              : ScoringPage(controller: controller),
        ),
      ],
    );
  }
}
