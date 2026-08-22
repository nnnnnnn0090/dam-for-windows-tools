// Project: DAM for Windows Tools
// File: desktop_integration.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'manual_video_store.dart';

/// ファイル選択とブラウザ起動を、アプリケーション層から切り離す境界です。
abstract interface class DesktopIntegration {
  /// 動画IDに割り当てるローカル動画を利用者へ選択させます。
  Future<File?> chooseVideo(String videoId);

  /// 指定URLをOSの既定アプリケーションで開きます。
  Future<void> openUrl(String url);
}

/// Windowsのファイル選択ダイアログと既定ブラウザを利用する実装です。
class WindowsDesktopIntegration implements DesktopIntegration {
  /// 状態を持たないWindows連携サービスを生成します。
  const WindowsDesktopIntegration();

  /// 対応動画形式だけを選べるWindowsダイアログを表示します。
  @override
  Future<File?> chooseVideo(String videoId) async {
    final result = await FilePicker.pickFile(
      dialogTitle: '$videoId の差し替え動画を選択',
      type: FileType.custom,
      allowedExtensions: ManualVideoStore.supportedExtensions,
    );
    final path = result?.path;
    return path == null ? null : File(path);
  }

  /// `explorer.exe`へURLを渡し、GUIを待たせず既定ブラウザを起動します。
  @override
  Future<void> openUrl(String url) async {
    await Process.start('explorer.exe', <String>[
      url,
    ], mode: ProcessStartMode.detached);
  }
}
