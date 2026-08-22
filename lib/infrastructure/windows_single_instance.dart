// Project: DAM for Windows Tools
// File: windows_single_instance.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../config/app_config.dart';

class SingleInstanceGuard {
  SingleInstanceGuard._(this._handle);

  static const int _errorAlreadyExists = 183;
  static const int _showWindowRestore = 9;

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
        _closeHandle(kernel32, handle);
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
        showWindow(window, _showWindowRestore);
        setForegroundWindow(window);
      }
    } finally {
      calloc.free(title);
    }
  }

  void release() => _closeHandle(DynamicLibrary.open('kernel32.dll'), _handle);

  static void _closeHandle(DynamicLibrary kernel32, Pointer<Void> handle) {
    final closeHandle = kernel32
        .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
    closeHandle(handle);
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
