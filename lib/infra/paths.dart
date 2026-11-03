import 'dart:io';

import 'package:path/path.dart' as p;

import '../app_config.dart';
import 'random_token.dart';

/// アプリが読み書きする場所をまとめます。データはすべてEXE横に置きます。
///
/// ```text
/// <root>/DAMforWindowsTools.exe
/// <root>/updater.exe
/// <root>/runtime/{ffmpeg.exe, dam-link.exe | node.exe + helper/}
/// <root>/DAMforWindowsToolsData/{settings.json, history.json, videos/, sessions/, updates/}
/// ```
class AppPaths {
  AppPaths({required this.root, required this.sessionId});

  /// EXEの場所を基準に解決します。開発時(`flutter run`)はカレントディレクトリに
  /// `helper/` があればそこをルートとみなします。
  factory AppPaths.resolve() {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final current = Directory.current.path;
    final isDevelopment =
        !Directory(p.join(executableDirectory, 'runtime')).existsSync() &&
        Directory(p.join(current, 'helper')).existsSync();
    return AppPaths(
      root: isDevelopment ? current : executableDirectory,
      sessionId: randomHex(12),
    );
  }

  final String root;
  final String sessionId;

  String get dataDirectory => p.join(root, AppConfig.dataDirectoryName);
  File get settingsFile => File(p.join(dataDirectory, 'settings.json'));
  File get historyFile => File(p.join(dataDirectory, 'history.json'));
  String get diagnosticsLogPath => p.join(dataDirectory, 'diagnostics.log');
  Directory get videosDirectory => Directory(p.join(dataDirectory, 'videos'));
  Directory get sessionsDirectory =>
      Directory(p.join(dataDirectory, 'sessions'));
  Directory get sessionDirectory =>
      Directory(p.join(sessionsDirectory.path, 'session-$sessionId'));
  Directory get hlsDirectory => Directory(p.join(sessionDirectory.path, 'hls'));
  Directory get updatesDirectory => Directory(p.join(dataDirectory, 'updates'));

  String get runtimeDirectory => p.join(root, 'runtime');
  File get applicationExecutable =>
      File(p.join(root, AppConfig.executableName));
  File get updaterExecutable =>
      File(p.join(root, AppConfig.updaterExecutableName));

  /// 配布ZIPから展開された構成かどうかです。自動更新はこの場合だけ有効です。
  bool get isPackaged =>
      Directory(runtimeDirectory).existsSync() &&
      applicationExecutable.existsSync() &&
      updaterExecutable.existsSync();

  /// 同梱のFFmpegを優先し、無ければ開発用に `tool/cache` のものを使います。
  String get ffmpegExecutable {
    for (final candidate in <String>[
      p.join(runtimeDirectory, 'ffmpeg.exe'),
      p.join(root, 'tool', 'cache', 'ffmpeg', 'ffmpeg.exe'),
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return p.join(runtimeDirectory, 'ffmpeg.exe');
  }

  /// 前回までのセッション一時領域を消し、今回の領域を作ります。
  Future<void> prepare() async {
    await sessionsDirectory.create(recursive: true);
    await for (final entity in sessionsDirectory.list(followLinks: false)) {
      if (entity is Directory &&
          p.basename(entity.path).startsWith('session-')) {
        await _deleteQuietly(entity);
      }
    }
    await hlsDirectory.create(recursive: true);
  }

  /// 今回のセッション一時領域を消します。
  Future<void> disposeSession() => _deleteQuietly(sessionDirectory);

  Future<void> _deleteQuietly(Directory directory) async {
    // 削除対象が必ずデータ領域の内側にあることを確かめてから消します。
    if (!p.isWithin(dataDirectory, directory.absolute.path)) {
      throw StateError('データ領域外の削除を拒否しました: ${directory.path}');
    }
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // 他プロセスが解放中のファイルは次回起動時に削除します。
    }
  }
}
