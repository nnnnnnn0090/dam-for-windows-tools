// Project: DAM for Windows Tools
// File: media/http_response_writer.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:convert';
import 'dart:io';

abstract final class HttpResponseWriter {
  static Future<void> error(
    HttpRequest request,
    int status,
    String text,
  ) async {
    try {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.text
        ..write('$text\n');
      await request.response.close();
    } on StateError {
      await request.response.close();
    }
  }

  static Future<void> manifest(HttpRequest request, String source) async {
    final output = utf8.encode(source);
    request.response.headers.contentType = ContentType(
      'application',
      'vnd.apple.mpegurl',
      charset: 'utf-8',
    );
    request.response.contentLength = output.length;
    if (request.method != 'HEAD') request.response.add(output);
    await request.response.close();
  }
}
