import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/states.dart';
import '../app_config.dart';
import '../infra/helper/dam_link.dart';
import 'theme.dart';
import 'widgets.dart';

/// 製品名・接続状態・更新・ライセンス・リモコン・再接続を並べた上部バーです。
class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  const AppHeader({super.key, required this.controller});

  final AppController controller;

  @override
  Size get preferredSize => const Size.fromHeight(52);

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
        ListenableBuilder(
          listenable: controller.connection,
          builder: (context, _) => Row(
            children: <Widget>[
              StatusDot(connectionColor(controller.connection.state)),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  controller.connection.detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xffc6cbd2),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        ListenableBuilder(
          listenable: controller.update,
          builder: (context, _) {
            final update = controller.update;
            return Tooltip(
              message: update.message,
              child: TextButton.icon(
                key: const Key('update-button'),
                onPressed: controller.updatesSupported && !update.busy
                    ? () => unawaited(checkAndPromptUpdate(context, controller))
                    : null,
                icon: update.busy
                    ? const SizedBox.square(
                        dimension: 15,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      )
                    : const Icon(Icons.system_update_alt, size: 17),
                label: Text(_updateLabel(update)),
              ),
            );
          },
        ),
        const SizedBox(width: 4),
        TextButton.icon(
          key: const Key('licenses-button'),
          onPressed: () => showLicensePage(
            context: context,
            applicationName: AppConfig.productName,
            applicationVersion: AppConfig.productVersion,
            applicationLegalese:
                'Copyright (c) 2026 nnnnnnn0090\nGPL-3.0-or-later\n\n'
                '${AppConfig.legalSummary}\n\nリモコンは信頼できる家庭内LAN専用です。',
          ),
          icon: const Icon(Icons.info_outline, size: 17),
          label: const Text('ライセンス'),
        ),
        const SizedBox(width: 4),
        ValueListenableBuilder<String?>(
          valueListenable: controller.remoteUrl,
          builder: (context, url, _) => TextButton.icon(
            key: const Key('remote-control-button'),
            onPressed: url == null
                ? null
                : () => unawaited(showRemoteControlDialog(context, controller)),
            icon: const Icon(Icons.qr_code_2, size: 17),
            label: const Text('リモコン'),
          ),
        ),
        const SizedBox(width: 4),
        TextButton(
          onPressed: () => unawaited(controller.reconnect()),
          child: const Text('再接続'),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  static String _updateLabel(UpdateState update) => switch (update.phase) {
    UpdatePhase.checking => '確認中',
    UpdatePhase.available => '更新 v${update.available?.version ?? ''}',
    UpdatePhase.downloading => '更新 ${update.progressPercent}%',
    UpdatePhase.restarting => '再起動中',
    _ => '更新',
  };
}

Color connectionColor(LinkState state) => switch (state) {
  LinkState.attached => AppColors.ok,
  LinkState.attaching => AppColors.accent,
  _ when state.isError => AppColors.error,
  _ => AppColors.warning,
};

/// 更新を確認し、あれば適用するか尋ねます。
Future<void> checkAndPromptUpdate(
  BuildContext context,
  AppController controller,
) async {
  if (controller.update.available == null) await controller.checkForUpdates();
  if (!context.mounted) return;
  if (controller.update.available != null) {
    await showUpdatePrompt(context, controller);
  } else {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(controller.update.message)));
  }
}

bool _updatePromptOpen = false;

/// 更新内容を表示し、承諾されたら更新を開始します。二重には開きません。
Future<void> showUpdatePrompt(
  BuildContext context,
  AppController controller,
) async {
  final update = controller.update.available;
  if (update == null || _updatePromptOpen) return;
  _updatePromptOpen = true;
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
    if (accepted == true) unawaited(controller.installUpdate());
  } finally {
    _updatePromptOpen = false;
  }
}

/// リモコン接続用のQRコードを表示します。
Future<void> showRemoteControlDialog(
  BuildContext context,
  AppController controller,
) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    key: const Key('remote-control-dialog'),
    title: const Text('リモコン'),
    content: SizedBox(
      width: 300,
      child: ValueListenableBuilder<String?>(
        valueListenable: controller.remoteUrl,
        builder: (context, url, _) => Column(
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
              style: TextStyle(fontSize: 11, color: AppColors.caution),
            ),
            const SizedBox(height: 16),
            if (url == null)
              const Text('LANに接続されていません')
            else
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
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('閉じる'),
      ),
      FilledButton.icon(
        key: const Key('remote-control-open-browser'),
        onPressed: () => unawaited(controller.openRemoteInBrowser()),
        icon: const Icon(Icons.open_in_new, size: 17),
        label: const Text('ブラウザで開く'),
      ),
    ],
  ),
);
