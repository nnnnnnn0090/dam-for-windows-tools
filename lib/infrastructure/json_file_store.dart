// Project: DAM for Windows Tools
// File: json_file_store.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';

/// 破損や巨大入力をアプリ停止へ波及させない、共通JSONファイル入出力です。
class JsonFileStore {
  /// 状態を持たないJSON入出力サービスを生成します。
  const JsonFileStore();

  /// 指定上限以内のJSONだけを読み、欠損・破損・I/O失敗時はnullを返します。
  Future<Object?> read(File file, {required int maximumBytes}) async {
    if (!await file.exists() || await file.length() > maximumBytes) return null;
    try {
      return jsonDecode(await file.readAsString());
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// 一時ファイルへ完全に書き出してから、保存先を原子的に置き換えます。
  Future<void> write(File destination, Object value) async {
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.tmp');
    try {
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(value),
        flush: true,
      );
      await replaceFileAtomically(temporary, destination);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
