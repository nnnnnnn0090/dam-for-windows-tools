// Project: DAM for Windows Tools
// File: home/video_page.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';

import '../../application/app_controller.dart';
import 'diagnostic_log_panel.dart';
import 'history_panel.dart';
import 'settings_panel.dart';

/// 動画差し替え設定、再生履歴、診断ログを縦に配置する主要画面です。
class VideoPage extends StatelessWidget {
  /// 各パネルが共有するアプリコントローラーを受け取ります。
  const VideoPage({super.key, required this.controller});

  final AppController controller;

  /// 設定を上、伸縮する履歴を中央、診断導線を下へ配置します。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SettingsPanel(controller: controller),
          const SizedBox(height: 12),
          Expanded(child: HistoryPanel(controller: controller)),
          const SizedBox(height: 4),
          DiagnosticLogPanel(controller: controller),
        ],
      ),
    );
  }
}
