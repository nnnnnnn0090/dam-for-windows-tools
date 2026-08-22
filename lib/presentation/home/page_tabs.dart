// Project: DAM for Windows Tools
// File: home/page_tabs.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';

/// 動画管理と採点表示を切り替える、デスクトップ向けタブ列です。
class PageTabs extends StatelessWidget {
  /// 選択位置と、親画面へ返す選択コールバックを受け取ります。
  const PageTabs({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// 固定高さのタブ列を構築します。
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: const BoxDecoration(
        color: Color(0xff15181d),
        border: Border(bottom: BorderSide(color: Color(0xff333840))),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(width: 8),
          _PageTab(
            label: '動画',
            selected: selectedIndex == 0,
            onTap: () => onSelected(0),
          ),
          _PageTab(
            label: '採点',
            selected: selectedIndex == 1,
            onTap: () => onSelected(1),
          ),
        ],
      ),
    );
  }
}

/// 選択状態を下線と文字色で示す、個別のタブです。
class _PageTab extends StatelessWidget {
  /// ラベル、選択状態、押下処理を受け取ります。
  const _PageTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Windowsのポインター操作に適した固定幅タブを構築します。
  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('page-tab-$label'),
      onTap: onTap,
      child: Container(
        width: 82,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? const Color(0xff4e91cb) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            color: selected ? const Color(0xffe0e3e8) : const Color(0xff9298a1),
          ),
        ),
      ),
    );
  }
}
