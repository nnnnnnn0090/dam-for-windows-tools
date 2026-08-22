// Project: DAM for Windows Tools
// File: atomic_file.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 一時ファイルを既存ファイルへ置き換え、途中書き込みの露出を防ぎます。
///
/// Windowsでは`MoveFileExW`の置換と書き込み完了フラグを使い、設定や
/// マニフェストが半端な内容で読み取られないようにします。
Future<void> replaceFileAtomically(File source, File destination) async {
  await destination.parent.create(recursive: true);
  if (!Platform.isWindows) {
    if (await destination.exists()) await destination.delete();
    await source.rename(destination.path);
    return;
  }

  const moveFileReplaceExisting = 0x1;
  const moveFileWriteThrough = 0x8;
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final moveFile = kernel32
      .lookupFunction<_MoveFileExWNative, _MoveFileExWDart>('MoveFileExW');
  final sourcePointer = source.path.toNativeUtf16();
  final destinationPointer = destination.path.toNativeUtf16();
  try {
    final result = moveFile(
      sourcePointer,
      destinationPointer,
      moveFileReplaceExisting | moveFileWriteThrough,
    );
    if (result == 0) {
      throw FileSystemException('ファイルの原子的な更新に失敗しました', destination.path);
    }
  } finally {
    calloc.free(sourcePointer);
    calloc.free(destinationPointer);
  }
}

/// Win32の`MoveFileExW`を呼び出すためのネイティブ関数シグネチャです。
typedef _MoveFileExWNative = Int32 Function(
  Pointer<Utf16>,
  Pointer<Utf16>,
  Uint32,
);

/// Dart側から`MoveFileExW`を呼び出すための関数シグネチャです。
typedef _MoveFileExWDart = int Function(Pointer<Utf16>, Pointer<Utf16>, int);
