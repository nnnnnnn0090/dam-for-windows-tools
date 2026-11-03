import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'json_lines.dart';

/// 接続ヘルパーの起動方法です。`docs/DAM_LINK_DESIGN.md` の2章に従って解決します。
class HelperCommand {
  const HelperCommand(this.executable, this.arguments, this.workingDirectory);

  final String executable;
  final List<String> arguments;
  final String workingDirectory;

  /// 解決順: `DAM_TOOLS_HELPER` → `runtime/dam-link.exe` →
  /// `runtime/node.exe runtime/helper/main.js` → 開発用 `node helper/main.js`。
  static HelperCommand? resolve(String root, Map<String, String> environment) {
    final override = environment['DAM_TOOLS_HELPER']?.trim() ?? '';
    // 実行ファイルのパスだけの指定は、空白を含んでいてもそのまま使います。
    if (override.isNotEmpty && File(override).existsSync()) {
      return HelperCommand(override, const <String>[], p.dirname(override));
    }
    if (override.isNotEmpty) {
      final parts = override.split(RegExp(r'\s+'));
      final script = parts.length > 1 ? parts.last : parts.first;
      return HelperCommand(
        parts.first,
        parts.skip(1).toList(),
        p.dirname(script),
      );
    }
    final runtime = p.join(root, 'runtime');
    final damLink = p.join(runtime, 'dam-link.exe');
    if (File(damLink).existsSync()) {
      return HelperCommand(damLink, const <String>[], runtime);
    }
    final bundledNode = p.join(runtime, 'node.exe');
    final bundledScript = p.join(runtime, 'helper', 'main.js');
    if (File(bundledNode).existsSync() && File(bundledScript).existsSync()) {
      return HelperCommand(bundledNode, <String>[
        bundledScript,
      ], p.dirname(bundledScript));
    }
    final developmentScript = p.join(root, 'helper', 'main.js');
    if (File(developmentScript).existsSync()) {
      final node = p.join(root, 'tool', 'cache', 'node', 'node.exe');
      return HelperCommand(
        File(node).existsSync() ? node : 'node.exe',
        <String>[developmentScript],
        p.dirname(developmentScript),
      );
    }
    return null;
  }
}

/// 接続ヘルパーの子プロセス1回分です。再起動は呼び出し側（[DamLink]）が行います。
class HelperProcess {
  HelperProcess._(this._process, this._onEvent, this._onLog) {
    _stdoutDone = _process.stdout
        .transform(const JsonLinesDecoder(maximumLineBytes: 4 * 1024 * 1024))
        .asyncMap(_dispatch) // 受信順に1件ずつ処理します。
        .drain<void>()
        .catchError((Object error) => _onLog('ヘルパー出力の読み取りに失敗しました: $error'));
    _stderrDone = _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((line) {
          if (line.trim().isNotEmpty) _onLog('helper: ${line.trim()}');
        })
        .catchError((Object _) {});
    // 書き込み先が先に閉じた場合のエラーはここで回収し、未処理例外にしません。
    unawaited(_process.stdin.done.catchError((Object _) => _closed = true));
    exitCode = _process.exitCode.then((code) async {
      _closed = true;
      await Future.wait(<Future<void>>[_stdoutDone, _stderrDone]);
      return code;
    });
  }

  static Future<HelperProcess> start({
    required HelperCommand command,
    required Map<String, String> environment,
    required Future<void> Function(Map<String, Object?> event) onEvent,
    required void Function(String message) onLog,
  }) async {
    final process = await Process.start(
      command.executable,
      command.arguments,
      workingDirectory: command.workingDirectory,
      environment: environment,
    );
    return HelperProcess._(process, onEvent, onLog);
  }

  static const int maximumCommandBytes = 64 * 1024;

  final Process _process;
  final Future<void> Function(Map<String, Object?> event) _onEvent;
  final void Function(String message) _onLog;
  late final Future<void> _stdoutDone;
  late final Future<void> _stderrDone;
  late final Future<int> exitCode;
  bool _closed = false;

  bool get isRunning => !_closed;
  int get pid => _process.pid;

  /// コマンドを1行送ります。終了済みなら `false` を返します。
  bool send(Map<String, Object?> command) {
    if (_closed) return false;
    final line = jsonEncode(command);
    if (line.length > maximumCommandBytes) {
      throw ArgumentError('ヘルパーへのコマンドが長すぎます');
    }
    try {
      _process.stdin.add(utf8.encode('$line\n'));
      return true;
    } on Object {
      _closed = true;
      return false;
    }
  }

  /// `shutdown` を送ってstdinを閉じ、`grace` 内に終わらなければ強制終了します。
  Future<void> stop({Duration grace = const Duration(seconds: 5)}) async {
    send(const <String, Object?>{'type': 'shutdown'});
    _closed = true;
    await _process.stdin.close().catchError((Object _) {});
    try {
      await exitCode.timeout(grace);
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
      await exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1);
    }
  }

  Future<void> _dispatch(JsonLinesItem item) async {
    if (item.error != null) {
      _onLog(item.error!);
    } else if (item.value != null) {
      try {
        await _onEvent(item.value!);
      } on Object catch (error) {
        _onLog('ヘルパーイベントの処理に失敗しました: $error');
      }
    }
  }
}
