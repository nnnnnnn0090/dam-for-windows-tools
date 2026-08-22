// Project: DAM for Windows Tools
// File: diagnostic_log.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

class DiagnosticLog {
  DiagnosticLog({this.maximumEntries = 500});

  final int maximumEntries;
  final List<String> _entries = <String>[];

  List<String> get entries => List<String>.unmodifiable(_entries);

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
