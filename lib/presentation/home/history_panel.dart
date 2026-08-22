// Project: DAM for Windows Tools
// File: home/history_panel.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';

import '../../application/app_controller.dart';
import '../widgets/panel.dart';
import 'history_list.dart';

class HistoryPanel extends StatelessWidget {
  const HistoryPanel({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tracks = controller.tracks;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: 43,
            child: Row(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Text(
                    '再生履歴 (${tracks.length})',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: tracks.isEmpty
                      ? null
                      : () => _confirmClearHistory(context),
                  child: const Text('履歴消去'),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: tracks.isEmpty
                ? const Center(
                    child: Text(
                      '再生履歴はありません',
                      style: TextStyle(color: Color(0xff888e98)),
                    ),
                  )
                : HistoryList(tracks: tracks, controller: controller),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('再生履歴を消去'),
        content: const Text('動画ID・アーティスト名・曲名の履歴を消去します。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('消去'),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.clearHistory();
  }
}
