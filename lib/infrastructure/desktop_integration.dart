// Project: DAM for Windows Tools
// File: desktop_integration.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'manual_video_store.dart';

abstract interface class DesktopIntegration {
  Future<File?> chooseVideo(String videoId);
  Future<void> openUrl(String url);
}

class WindowsDesktopIntegration implements DesktopIntegration {
  const WindowsDesktopIntegration();

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

  @override
  Future<void> openUrl(String url) async {
    await Process.start('explorer.exe', <String>[
      url,
    ], mode: ProcessStartMode.detached);
  }
}
