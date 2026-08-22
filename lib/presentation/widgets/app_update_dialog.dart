// Project: DAM for Windows Tools
// File: widgets/app_update_dialog.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/app_controller.dart';
import '../../domain/app_update.dart';

/// 指定更新の内容と自動再起動を説明し、利用者が同意した場合だけ取得を開始します。
Future<bool> showAppUpdatePrompt(
  BuildContext context,
  AppController controller,
  AppUpdate update,
) async {
  if (!controller.beginUpdatePrompt()) return false;
  try {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text('バージョン ${update.version} があります'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('更新をダウンロードして適用し、自動で再起動します。'),
              if (update.notes.isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                const Text(
                  '更新内容',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    child: SelectableText(update.notes),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('あとで'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.system_update_alt, size: 18),
            label: const Text('更新する'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      unawaited(controller.installAvailableUpdate());
      return true;
    }
    return false;
  } finally {
    controller.endUpdatePrompt();
  }
}

/// GUIの更新ボタンから最新版を確認し、結果に応じて確認画面または短い通知を出します。
Future<void> checkAndPromptForAppUpdate(
  BuildContext context,
  AppController controller,
) async {
  final update =
      controller.availableUpdate ?? await controller.checkForUpdates();
  if (!context.mounted) return;
  if (update != null) {
    await showAppUpdatePrompt(context, controller, update);
    return;
  }
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(controller.updateStatus)));
}
