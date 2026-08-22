// Project: DAM for Windows Tools
// File: sidecar/json_line_process.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 1行のJSONオブジェクトを処理するコールバック型です。
typedef JsonLineHandler = FutureOr<void> Function(Map<String, dynamic> value);

/// 子プロセスの終了コードを処理するコールバック型です。
typedef ProcessExitHandler = FutureOr<void> Function(int exitCode);

/// Nodeヘルパーの起動・終了と、双方向JSON Linesストリームを管理します。
class JsonLineProcess {
  /// 実行条件と出力処理先を受け取り、未起動のプロセス管理器を生成します。
  JsonLineProcess({
    required this.executable,
    required this.entryPoint,
    required this.workingDirectory,
    required this.environment,
    required this.onMessage,
    required this.onExit,
    required this.onLog,
  });

  static const int maximumLineLength = 4 * 1024 * 1024;

  final String executable;
  final String entryPoint;
  final String workingDirectory;
  final Map<String, String> environment;
  final JsonLineHandler onMessage;
  final ProcessExitHandler onExit;
  final void Function(String message) onLog;

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  bool _stopping = false;

  /// 管理対象プロセスが存在するか返します。
  bool get isRunning => _process != null;

  /// 子プロセスを起動し、標準出力と標準エラーの非同期購読を開始します。
  Future<void> start() async {
    if (_process != null) return;
    _stopping = false;
    final process = await Process.start(
      executable,
      <String>[entryPoint],
      workingDirectory: workingDirectory,
      runInShell: executable == 'node',
      environment: environment,
    );
    _process = process;
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: (Object error) => onLog('Fridaヘルパー標準出力エラー: $error'),
        );
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isNotEmpty) onLog('Fridaヘルパー: $line');
        });
    unawaited(
      process.exitCode.then((exitCode) async {
        if (identical(_process, process)) _process = null;
        if (!_stopping) await onExit(exitCode);
      }),
    );
  }

  /// JSONオブジェクトを1行へ符号化して標準入力へ送り、送信失敗をログ化します。
  void send(Map<String, dynamic> value) {
    final process = _process;
    if (process == null) return;
    try {
      process.stdin.writeln(jsonEncode(value));
    } on Object catch (error) {
      onLog('Fridaヘルパーへの送信に失敗しました: $error');
    }
  }

  /// 正常終了要求を送り、3秒で応答しなければプロセスを強制終了します。
  Future<void> stop() async {
    final process = _process;
    if (process == null) return;
    _stopping = true;
    send(const <String, dynamic>{'type': 'shutdown'});
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill();
    }
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    await process.stdin.close();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _process = null;
  }

  /// 標準出力1行のサイズとJSON型を検証し、プロトコル外出力はログへ残します。
  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    if (line.length > maximumLineLength) {
      onLog('Fridaヘルパーからの巨大なJSON Linesメッセージを拒否しました');
      return;
    }
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) {
        final result = onMessage(decoded);
        if (result is Future<void>) {
          unawaited(
            result.catchError(
              (Object error) => onLog('Fridaイベント処理に失敗しました: $error'),
            ),
          );
        }
        return;
      }
    } on FormatException {
      // JSONではない標準出力も失わず、原因調査に使える診断行として残します。
    }
    onLog('Fridaヘルパー: $line');
  }
}
