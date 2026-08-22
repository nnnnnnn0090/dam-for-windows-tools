// Project: DAM for Windows Tools
// File: app_paths.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart';

class AppPaths {
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

  File get settingsFile => File(p.join(supportDirectory.path, 'settings.json'));
  File get historyFile => File(p.join(supportDirectory.path, 'history.json'));
  Directory get manualVideosDirectory =>
      Directory(p.join(supportDirectory.path, 'videos'));
  Directory get hlsDirectory => Directory(p.join(sessionDirectory.path, 'hls'));

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
          // A prior helper may still be releasing a file. The current session
          // uses a unique directory, so leaving this stale directory is safe.
        }
      }
    }
  }

  static String _randomToken(int bytes) {
    final random = Random.secure();
    return List<int>.generate(
      bytes,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}

typedef _CreateMutexWNative = Pointer<Void> Function(
  Pointer<Void>,
  Int32,
  Pointer<Utf16>,
);
typedef _CreateMutexWDart = Pointer<Void> Function(
  Pointer<Void>,
  int,
  Pointer<Utf16>,
);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandleDart = int Function(Pointer<Void>);
typedef _FindWindowWNative = Pointer<Void> Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
);
typedef _FindWindowWDart = Pointer<Void> Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
);
typedef _ShowWindowNative = Int32 Function(Pointer<Void>, Int32);
typedef _ShowWindowDart = int Function(Pointer<Void>, int);
typedef _SetForegroundWindowNative = Int32 Function(Pointer<Void>);
typedef _SetForegroundWindowDart = int Function(Pointer<Void>);

class SingleInstanceGuard {
  SingleInstanceGuard._(this._handle);

  static const int _errorAlreadyExists = 183;
  final Pointer<Void> _handle;

  static SingleInstanceGuard? acquire() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createMutex = kernel32
        .lookupFunction<_CreateMutexWNative, _CreateMutexWDart>('CreateMutexW');
    final getLastError = kernel32
        .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
    final name = AppConfig.singletonMutexName.toNativeUtf16();
    try {
      final handle = createMutex(nullptr, 0, name);
      if (handle == nullptr) return null;
      if (getLastError() == _errorAlreadyExists) {
        final closeHandle = kernel32
            .lookupFunction<_CloseHandleNative, _CloseHandleDart>(
              'CloseHandle',
            );
        closeHandle(handle);
        return null;
      }
      return SingleInstanceGuard._(handle);
    } finally {
      calloc.free(name);
    }
  }

  static void activateExistingWindow() {
    final user32 = DynamicLibrary.open('user32.dll');
    final findWindow = user32
        .lookupFunction<_FindWindowWNative, _FindWindowWDart>('FindWindowW');
    final showWindow = user32
        .lookupFunction<_ShowWindowNative, _ShowWindowDart>('ShowWindow');
    final setForegroundWindow = user32
        .lookupFunction<_SetForegroundWindowNative, _SetForegroundWindowDart>(
          'SetForegroundWindow',
        );
    final title = AppConfig.productName.toNativeUtf16();
    try {
      final window = findWindow(nullptr, title);
      if (window != nullptr) {
        showWindow(window, 9); // SW_RESTORE
        setForegroundWindow(window);
      }
    } finally {
      calloc.free(title);
    }
  }

  void release() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final closeHandle = kernel32
        .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
    closeHandle(_handle);
  }
}
