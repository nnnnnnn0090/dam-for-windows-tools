// Project: DAM for Windows Tools
// File: windows_single_instance.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../config/app_config.dart';

/// 名前付きMutexの所有権で、パッチとポートを扱うアプリの多重起動を防ぎます。
class SingleInstanceGuard {
  /// 取得済みWin32 Mutexハンドルを管理するガードを生成します。
  SingleInstanceGuard._(this._handle);

  static const int _errorAlreadyExists = 183;
  static const int _showWindowRestore = 9;

  final Pointer<Void> _handle;

  /// プロセス固有のMutexを取得し、既存所有者がいる場合はnullを返します。
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
        _closeHandle(kernel32, handle);
        return null;
      }
      return SingleInstanceGuard._(handle);
    } finally {
      calloc.free(name);
    }
  }

  /// 二重起動時に既存ウィンドウを復元して前面へ移動します。
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
        showWindow(window, _showWindowRestore);
        setForegroundWindow(window);
      }
    } finally {
      calloc.free(title);
    }
  }

  /// アプリ終了時にMutexハンドルを閉じ、次回起動を許可します。
  void release() => _closeHandle(DynamicLibrary.open('kernel32.dll'), _handle);

  /// 指定DLLの`CloseHandle`でWin32ハンドルを解放します。
  static void _closeHandle(DynamicLibrary kernel32, Pointer<Void> handle) {
    final closeHandle = kernel32
        .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
    closeHandle(handle);
  }
}

/// Win32 `CreateMutexW`のネイティブ関数シグネチャです。
typedef _CreateMutexWNative = Pointer<Void> Function(
  Pointer<Void>,
  Int32,
  Pointer<Utf16>,
);

/// Dart側から`CreateMutexW`を呼び出すための関数シグネチャです。
typedef _CreateMutexWDart = Pointer<Void> Function(
  Pointer<Void>,
  int,
  Pointer<Utf16>,
);

/// Win32 `GetLastError`のネイティブ関数シグネチャです。
typedef _GetLastErrorNative = Uint32 Function();

/// Dart側から`GetLastError`を呼び出すための関数シグネチャです。
typedef _GetLastErrorDart = int Function();

/// Win32 `CloseHandle`のネイティブ関数シグネチャです。
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);

/// Dart側から`CloseHandle`を呼び出すための関数シグネチャです。
typedef _CloseHandleDart = int Function(Pointer<Void>);

/// Win32 `FindWindowW`のネイティブ関数シグネチャです。
typedef _FindWindowWNative = Pointer<Void> Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
);

/// Dart側から`FindWindowW`を呼び出すための関数シグネチャです。
typedef _FindWindowWDart = Pointer<Void> Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
);

/// Win32 `ShowWindow`のネイティブ関数シグネチャです。
typedef _ShowWindowNative = Int32 Function(Pointer<Void>, Int32);

/// Dart側から`ShowWindow`を呼び出すための関数シグネチャです。
typedef _ShowWindowDart = int Function(Pointer<Void>, int);

/// Win32 `SetForegroundWindow`のネイティブ関数シグネチャです。
typedef _SetForegroundWindowNative = Int32 Function(Pointer<Void>);

/// Dart側から`SetForegroundWindow`を呼び出すための関数シグネチャです。
typedef _SetForegroundWindowDart = int Function(Pointer<Void>);
