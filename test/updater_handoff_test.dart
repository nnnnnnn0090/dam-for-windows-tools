// Project: DAM for Windows Tools
// File: updater_handoff_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Windows標準PowerShellの絶対パスを現在の環境から解決します。
File _powershellExecutable() {
  final windowsRoot = Platform.environment['SystemRoot'];
  if (windowsRoot == null || windowsRoot.isEmpty) {
    throw StateError('SystemRoot is unavailable');
  }
  return File(
    '$windowsRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
  );
}

/// PATHに登録されたDart SDK実行ファイルを子プロセス試験用に取得します。
Future<String> _dartExecutable() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    final bundled = File('$flutterRoot\\bin\\cache\\dart-sdk\\bin\\dart.exe');
    if (await bundled.exists()) return bundled.path;
  }
  final result = await Process.run('where.exe', <String>['flutter.bat']);
  if (result.exitCode != 0) throw StateError('flutter.bat is unavailable');
  final flutter = result.stdout
      .toString()
      .split(RegExp(r'[\r\n]+'))
      .firstWhere((line) => line.trim().isNotEmpty)
      .trim();
  final bundled = File(
    '${File(flutter).parent.parent.path}\\bin\\cache\\dart-sdk\\bin\\dart.exe',
  );
  if (!await bundled.exists()) throw StateError('dart.exe is unavailable');
  return bundled.path;
}

/// 指定マーカーファイルが生成されるまで上限時間付きで待機します。
Future<void> _waitForFile(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('Marker was not created: ${file.path}');
}

/// PowerShellがスクリプトを解放するまで短時間再試行して試験領域を削除します。
Future<void> _deleteDirectoryEventually(Directory directory) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 19) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

/// 親Dartプロセス終了後もPowerShell更新処理が継続することを実プロセスで検証します。
void main() {
  test('updater survives its launching Dart process', () async {
    if (!Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('dam-updater-handoff-');
    try {
      final ready = File('${root.path}\\ready.txt');
      final complete = File('${root.path}\\complete.txt');
      final worker = File('${root.path}\\worker.ps1');
      await worker.writeAsString(r'''
param(
  [Parameter(Mandatory = $true)][int]$ParentProcessId,
  [Parameter(Mandatory = $true)][string]$ReadyPath,
  [Parameter(Mandatory = $true)][string]$CompletePath
)
Set-Content -LiteralPath $ReadyPath -Value 'ready' -NoNewline -Encoding ascii
while (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue) {
  Start-Sleep -Milliseconds 50
}
Set-Content -LiteralPath $CompletePath -Value 'complete' -NoNewline -Encoding ascii
''', flush: true);

      final probe = await Process.run(
        await _dartExecutable(),
        <String>[
          'run',
          'test/support/updater_handoff_probe.dart',
          _powershellExecutable().path,
          worker.path,
          ready.path,
          complete.path,
        ],
        workingDirectory: Directory.current.path,
      ).timeout(const Duration(seconds: 30));
      expect(probe.exitCode, 0, reason: '${probe.stdout}\n${probe.stderr}');
      await _waitForFile(complete);
      expect(await ready.readAsString(), 'ready');
      expect(await complete.readAsString(), 'complete');
    } finally {
      await _deleteDirectoryEventually(root);
    }
  });
}
