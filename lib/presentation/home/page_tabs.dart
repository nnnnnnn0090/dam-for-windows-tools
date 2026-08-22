// Project: DAM for Windows Tools
// File: home/page_tabs.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';

class PageTabs extends StatelessWidget {
  const PageTabs({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

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

class _PageTab extends StatelessWidget {
  const _PageTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

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
