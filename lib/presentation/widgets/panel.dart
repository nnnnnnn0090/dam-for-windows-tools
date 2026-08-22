// Project: DAM for Windows Tools
// File: widgets/panel.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';

/// 主要画面で共通使用する、角丸と境界線を持つ内容領域です。
class Panel extends StatelessWidget {
  /// パネル内へ表示するWidgetを受け取ります。
  const Panel({super.key, required this.child});

  final Widget child;

  /// 製品共通の背景・境界・クリッピングを適用します。
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xff171a1f),
        border: Border.all(color: const Color(0xff333840)),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// パネル先頭の見出し余白と文字スタイルを統一します。
class PanelTitle extends StatelessWidget {
  /// 表示する見出し文字列を受け取ります。
  const PanelTitle(this.text, {super.key});

  final String text;

  /// 左揃えの省スペースなパネル見出しを構築します。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 10),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}
