// Project: DAM for Windows Tools
// File: home/fatal_error_view.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';

import '../widgets/panel.dart';

/// 初期化を継続できない場合に、コピー可能な原因だけを中央表示します。
class FatalErrorView extends StatelessWidget {
  /// 利用者が診断へ使えるエラー文字列を受け取ります。
  const FatalErrorView({super.key, required this.error});

  final String error;

  /// 通常操作を隠し、起動失敗と詳細を明確に示すパネルを構築します。
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Panel(
        child: Container(
          width: 520,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '起動できませんでした',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              SelectableText(
                error,
                style: const TextStyle(color: Color(0xffc7a5a9)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
