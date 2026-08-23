// Project: DAM for Windows Tools
// File: windows_updater_launcher.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Windows PowerShellの更新処理を隠しプロセスで起動し、開始確認までを保証します。
///
/// 更新側が準備完了マーカーを作る前に終了した場合は標準出力を失敗理由として返し、
/// 更新処理が存在しない状態で親アプリだけが終了することを防ぎます。
class WindowsUpdaterLauncher {
  /// 更新スクリプトを起動し、親アプリ終了待ちへ入ったことを確認してから戻ります。
  Future<void> launch({
    required File powershell,
    required File script,
    required File readyMarker,
    required Directory workingDirectory,
    required List<String> scriptArguments,
  }) async {
    if (await readyMarker.exists()) await readyMarker.delete();
    final process = await Process.start(
      powershell.path,
      <String>[
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        ...scriptArguments,
      ],
      mode: ProcessStartMode.normal,
      workingDirectory: workingDirectory.path,
    );
    final output = StringBuffer();
    final stdoutDone = process.stdout
        .listen((bytes) => _appendOutput(output, bytes))
        .asFuture<void>();
    final stderrDone = process.stderr
        .listen((bytes) => _appendOutput(output, bytes))
        .asFuture<void>();
    final exitCode = process.exitCode;
    try {
      final outcome = await Future.any<Object>(<Future<Object>>[
        _waitForReady(readyMarker).then<Object>((_) => readyMarker),
        exitCode.then<Object>((code) => code),
      ]);
      if (outcome is int) {
        await Future.wait<void>(<Future<void>>[stdoutDone, stderrDone]);
        final detail = output.toString().trim();
        throw StateError(
          detail.isEmpty
              ? '更新プロセスが開始前に終了しました (終了コード $outcome)'
              : '更新プロセスを開始できませんでした: $detail',
        );
      }
    } on TimeoutException {
      process.kill();
      await exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
      throw StateError('更新プロセスの開始確認がタイムアウトしました');
    }
  }

  /// PowerShellが開始済みマーカーを作るまで上限時間付きで待機します。
  static Future<void> _waitForReady(File readyMarker) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (await readyMarker.exists()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('Updater ready marker was not created');
  }

  /// 更新プロセスの起動前出力を上限付きで保持し、具体的な失敗理由を残します。
  static void _appendOutput(StringBuffer output, List<int> bytes) {
    if (output.length >= 4000) return;
    final remaining = 4000 - output.length;
    final decoded = latin1.decode(bytes, allowInvalid: true);
    output.write(
      decoded.length <= remaining ? decoded : decoded.substring(0, remaining),
    );
  }
}
