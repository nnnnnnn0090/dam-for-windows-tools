// Project: DAM for Windows Tools
// File: home/app_header.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';

import '../../application/app_controller.dart';
import '../../config/app_config.dart';
import '../../domain/app_update.dart';
import '../widgets/app_update_dialog.dart';
import '../widgets/remote_control_dialog.dart';

/// 製品名、DAM接続状態、ライセンス、リモコン、再接続を横一列に表示します。
class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  /// 表示と操作に使うアプリコントローラーを受け取ります。
  const AppHeader({super.key, required this.controller});

  final AppController controller;

  /// Windows向けに固定したヘッダー高さを返します。
  @override
  Size get preferredSize => const Size.fromHeight(52);

  /// 接続状態を常時確認できる、最小限のアプリバーを構築します。
  @override
  Widget build(BuildContext context) {
    return AppBar(
      toolbarHeight: preferredSize.height,
      titleSpacing: 16,
      title: const Row(
        children: <Widget>[
          Flexible(
            child: Text(
              AppConfig.productName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          SizedBox(width: 8),
          Text(
            'v${AppConfig.productVersion}',
            style: TextStyle(fontSize: 11, color: Color(0xff8f969f)),
          ),
        ],
      ),
      actions: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: connectionColor(controller.connectionCode),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Text(
            controller.connectionState,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Color(0xffc6cbd2)),
          ),
        ),
        const SizedBox(width: 12),
        Tooltip(
          message: controller.updateStatus,
          child: TextButton.icon(
            key: const Key('update-button'),
            onPressed:
                controller.initialized &&
                    controller.updatesSupported &&
                    !controller.updateBusy &&
                    !controller.shuttingDown
                ? () => checkAndPromptForAppUpdate(context, controller)
                : null,
            icon: updateButtonIcon(controller.updatePhase),
            label: Text(updateButtonLabel(controller)),
          ),
        ),
        const SizedBox(width: 4),
        TextButton.icon(
          key: const Key('licenses-button'),
          onPressed: () => showLicensePage(
            context: context,
            applicationName: AppConfig.productName,
            applicationVersion: AppConfig.productVersion,
            applicationLegalese:
                'Copyright (c) 2026 nnnnnnn0090\n'
                'GPL-3.0-or-later\n\n'
                '${AppConfig.legalSummary}\n\n'
                'リモコンは信頼できる家庭内LAN専用です。',
          ),
          icon: const Icon(Icons.info_outline, size: 17),
          label: const Text('ライセンス'),
        ),
        const SizedBox(width: 4),
        TextButton.icon(
          key: const Key('remote-control-button'),
          onPressed: controller.remoteControlUrl == null
              ? null
              : () => showRemoteControlDialog(context, controller),
          icon: const Icon(Icons.qr_code_2, size: 17),
          label: const Text('リモコン'),
        ),
        const SizedBox(width: 4),
        TextButton(
          onPressed: controller.initialized ? controller.reconnect : null,
          child: const Text('再接続'),
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}

/// 更新段階を、ヘッダー内で幅を取り過ぎない短いボタン表示へ変換します。
String updateButtonLabel(AppController controller) {
  switch (controller.updatePhase) {
    case AppUpdatePhase.checking:
      return '確認中';
    case AppUpdatePhase.available:
      return '更新 v${controller.availableUpdate?.version ?? ''}';
    case AppUpdatePhase.downloading:
      return '更新 ${controller.updateProgressPercent}%';
    case AppUpdatePhase.restarting:
      return '再起動中';
    case AppUpdatePhase.idle:
    case AppUpdatePhase.latest:
    case AppUpdatePhase.failed:
      return '更新';
  }
}

/// 通信中は小さな進捗表示、それ以外は更新操作を示す固定アイコンを返します。
Widget updateButtonIcon(AppUpdatePhase phase) {
  if (phase == AppUpdatePhase.checking ||
      phase == AppUpdatePhase.downloading ||
      phase == AppUpdatePhase.restarting) {
    return const SizedBox.square(
      dimension: 15,
      child: CircularProgressIndicator(strokeWidth: 1.8),
    );
  }
  return const Icon(Icons.system_update_alt, size: 17);
}

/// Sidecarの接続状態コードを、ヘッダー表示用の信号色へ変換します。
Color connectionColor(String state) {
  switch (state) {
    case 'attached':
      return const Color(0xff4fb477);
    case 'unsupported':
    case 'attach-error':
    case 'helper-exited':
    case 'failed':
      return const Color(0xffd96767);
    case 'attaching':
      return const Color(0xff5b9bd5);
    default:
      return const Color(0xffc59a46);
  }
}
