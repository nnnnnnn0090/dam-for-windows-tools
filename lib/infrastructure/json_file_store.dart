// Project: DAM for Windows Tools
// File: json_file_store.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';

class JsonFileStore {
  const JsonFileStore();

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
