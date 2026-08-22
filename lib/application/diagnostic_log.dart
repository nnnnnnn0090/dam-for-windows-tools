// Project: DAM for Windows Tools
// File: diagnostic_log.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

/// 長時間起動でもメモリを増やし続けない、GUI表示用の診断ログです。
class DiagnosticLog {
  /// 保持する最大行数を指定して空のログを生成します。
  DiagnosticLog({this.maximumEntries = 500});

  final int maximumEntries;
  final List<String> _entries = <String>[];

  /// 呼び出し側から変更できないログ一覧を返します。
  List<String> get entries => List<String>.unmodifiable(_entries);

  /// ミリ秒までのローカル時刻を付けて1行追加し、古い行を上限まで削ります。
  void add(String message, {DateTime? at}) {
    final timestamp = (at ?? DateTime.now()).toIso8601String().substring(
      11,
      23,
    );
    _entries.add('$timestamp $message');
    if (_entries.length > maximumEntries) {
      _entries.removeRange(0, _entries.length - maximumEntries);
    }
  }
}
