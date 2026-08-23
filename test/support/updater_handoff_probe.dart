// Project: DAM for Windows Tools
// File: test/support/updater_handoff_probe.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:io';

import 'package:dam_for_windows_tools/infrastructure/windows_updater_launcher.dart';

/// テスト用更新プロセスへ引き継いだ直後に終了し、子プロセスが継続するか検証します。
Future<void> main(List<String> arguments) async {
  if (arguments.length != 4) exit(64);
  final powershell = File(arguments[0]);
  final worker = File(arguments[1]);
  final ready = File(arguments[2]);
  final complete = File(arguments[3]);
  await WindowsUpdaterLauncher().launch(
    powershell: powershell,
    script: worker,
    readyMarker: ready,
    workingDirectory: worker.parent,
    scriptArguments: <String>[
      '-ParentProcessId',
      pid.toString(),
      '-ReadyPath',
      ready.path,
      '-CompletePath',
      complete.path,
    ],
  );
  exit(0);
}
