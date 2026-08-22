// Project: DAM for Windows Tools
// File: app_paths.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../config/app_config.dart';

/// 配布物、永続データ、今回だけの一時データの配置を一元管理します。
///
/// 削除対象をセッション配下へ限定するため、パスの組み立てと安全性検証を
/// 個々のサービスへ分散させません。
class AppPaths {
  /// 検証済みの各ディレクトリと同梱実行ファイルからパス集合を生成します。
  AppPaths._({
    required this.supportDirectory,
    required this.sessionParent,
    required this.sessionDirectory,
    required this.runtimeDirectory,
    required this.sidecarEntry,
    required this.nodeExecutable,
    required this.ffmpegExecutable,
  });

  final Directory supportDirectory;
  final Directory sessionParent;
  final Directory sessionDirectory;
  final Directory runtimeDirectory;
  final File sidecarEntry;
  final String nodeExecutable;
  final String ffmpegExecutable;

  /// テスト用ルートの外へ書き込まない、固定パス構成を生成します。
  factory AppPaths.forTesting({
    required Directory root,
    String nodeExecutable = 'node',
    String ffmpegExecutable = 'ffmpeg',
  }) {
    final support = Directory(p.join(root.path, AppConfig.dataDirectoryName));
    final parent = Directory(p.join(support.path, 'sessions'));
    final session = Directory(p.join(parent.path, 'session-test'));
    final runtime = Directory(p.join(root.path, 'runtime'));
    return AppPaths._(
      supportDirectory: support,
      sessionParent: parent,
      sessionDirectory: session,
      runtimeDirectory: runtime,
      sidecarEntry: File(p.join(root.path, 'sidecar', 'main.js')),
      nodeExecutable: nodeExecutable,
      ffmpegExecutable: ffmpegExecutable,
    );
  }

  /// EXE横のデータフォルダに置く設定ファイルを返します。
  File get settingsFile => File(p.join(supportDirectory.path, 'settings.json'));

  /// URLや時刻を含まない曲履歴ファイルを返します。
  File get historyFile => File(p.join(supportDirectory.path, 'history.json'));

  /// 利用者が取り込んだ差し替え動画の永続ディレクトリを返します。
  Directory get manualVideosDirectory =>
      Directory(p.join(supportDirectory.path, 'videos'));

  /// 今回の起動で生成したHLSだけを置く一時ディレクトリを返します。
  Directory get hlsDirectory => Directory(p.join(sessionDirectory.path, 'hls'));

  /// 実行位置を解決し、前回残骸を清掃して今回専用のセッションを作成します。
  ///
  /// 配布版では同梱Node/FFmpegを優先し、開発時だけPATH上の実行ファイルへ
  /// 退避できるようにしています。
  static Future<AppPaths> create({Directory? applicationDirectory}) async {
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final cwd = Directory.current;
    final applicationRoot =
        applicationDirectory ??
        _resolveApplicationDirectory(executableDirectory, cwd);
    final support = Directory(
      p.join(applicationRoot.path, AppConfig.dataDirectoryName),
    );
    await support.create(recursive: true);

    final parent = Directory(p.join(support.path, 'sessions'));
    await parent.create(recursive: true);
    await _cleanupStaleSessions(parent);

    final session = Directory(
      p.join(parent.path, 'session-${_randomToken(12)}'),
    );
    await session.create(recursive: true);
    final hls = Directory(p.join(session.path, 'hls'));
    await hls.create(recursive: true);

    final runtimeCandidates = <Directory>[
      Directory(p.join(applicationRoot.path, 'runtime')),
      Directory(p.join(cwd.path, 'runtime')),
    ];
    final runtime = runtimeCandidates.firstWhere(
      (candidate) => candidate.existsSync(),
      orElse: () => runtimeCandidates.first,
    );
    final sidecarCandidates = <File>[
      File(p.join(runtime.path, 'helper', 'main.js')),
      File(p.join(cwd.path, 'sidecar', 'main.js')),
    ];
    final sidecar = sidecarCandidates.firstWhere(
      (candidate) => candidate.existsSync(),
      orElse: () => sidecarCandidates.first,
    );
    final bundledNode = File(p.join(runtime.path, 'node.exe'));
    final bundledFfmpeg = File(p.join(runtime.path, 'ffmpeg.exe'));

    return AppPaths._(
      supportDirectory: support,
      sessionParent: parent,
      sessionDirectory: session,
      runtimeDirectory: runtime,
      sidecarEntry: sidecar,
      nodeExecutable: bundledNode.existsSync() ? bundledNode.path : 'node',
      ffmpegExecutable: bundledFfmpeg.existsSync()
          ? bundledFfmpeg.path
          : 'ffmpeg',
    );
  }

  /// 配布版とソース実行の両方で、runtimeが存在する実際のアプリルートを選びます。
  static Directory _resolveApplicationDirectory(
    Directory executableDirectory,
    Directory cwd,
  ) {
    if (Directory(p.join(executableDirectory.path, 'runtime')).existsSync()) {
      return executableDirectory;
    }
    if (Directory(p.join(cwd.path, 'runtime')).existsSync() ||
        Directory(p.join(cwd.path, 'sidecar')).existsSync()) {
      return cwd;
    }
    return executableDirectory;
  }

  /// 正規化したセッションパスが管理領域内にあることを確認してから削除します。
  Future<void> disposeSession() async {
    final parentPath = p.normalize(p.absolute(sessionParent.path));
    final sessionPath = p.normalize(p.absolute(sessionDirectory.path));
    if (!p.isWithin(parentPath, sessionPath)) {
      throw StateError('一時領域の安全性検証に失敗しました: $sessionPath');
    }
    if (await sessionDirectory.exists()) {
      await sessionDirectory.delete(recursive: true);
    }
  }

  /// 異常終了で残った過去セッションだけを、リンクを追わずに削除します。
  static Future<void> _cleanupStaleSessions(Directory parent) async {
    final parentPath = p.normalize(p.absolute(parent.path));
    await for (final entity in parent.list(followLinks: false)) {
      if (entity is! Directory ||
          !p.basename(entity.path).startsWith('session-')) {
        continue;
      }
      final target = p.normalize(p.absolute(entity.path));
      if (p.isWithin(parentPath, target)) {
        try {
          await entity.delete(recursive: true);
        } on FileSystemException {
          // 前回のヘルパーがファイルを解放中でも、今回のセッションは別名なので
          // 安全に続行できます。削除できない残骸は次回起動時に再試行します。
        }
      }
    }
  }

  /// 推測困難なセッション名を作るため、暗号学的乱数を16進文字列へ変換します。
  static String _randomToken(int bytes) {
    final random = Random.secure();
    return List<int>.generate(
      bytes,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}
