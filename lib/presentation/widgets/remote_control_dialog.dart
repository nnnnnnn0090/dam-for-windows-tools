// Project: DAM for Windows Tools
// File: widgets/remote_control_dialog.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';

import '../../application/app_controller.dart';
import 'qr_code_view.dart';

/// 同一Wi-Fi端末向けURLをQRコードで示し、PCブラウザからも開けるダイアログを表示します。
Future<void> showRemoteControlDialog(
  BuildContext context,
  AppController controller,
) async {
  final url = controller.remoteControlUrl;
  if (url == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('remote-control-dialog'),
      title: const Text('リモコン'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'スマホをこのPCと同じWi-Fiに接続して、QRコードを読み取ってください。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 8),
            const Text(
              '信頼できる家庭内Wi-Fi専用です。公共・来客用Wi-Fiでは使用しないでください。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Color(0xffffc66d)),
            ),
            const SizedBox(height: 16),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(10),
              child: QrCodeView(
                key: const Key('remote-control-qr'),
                data: url,
                size: 225,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('閉じる'),
        ),
        FilledButton.icon(
          key: const Key('remote-control-open-browser'),
          onPressed: controller.openRemoteControl,
          icon: const Icon(Icons.open_in_new, size: 17),
          label: const Text('ブラウザで開く'),
        ),
      ],
    ),
  );
}
