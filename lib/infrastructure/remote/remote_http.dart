// Project: DAM for Windows Tools
// File: remote/remote_http.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:convert';
import 'dart:io';

class RemoteHttpProblem implements Exception {
  const RemoteHttpProblem(this.status, this.message);

  final int status;
  final String message;
}

abstract final class RemoteHttp {
  static const int maximumRequestBytes = 4096;

  static void verifySameOrigin(HttpRequest request, String? serverUrl) {
    final origin = request.headers.value('Origin');
    if (origin == null) return;
    if (serverUrl == null) {
      throw const RemoteHttpProblem(503, '準備中です');
    }
    final uri = Uri.parse(serverUrl);
    if (origin != '${uri.scheme}://${uri.authority}') {
      throw const RemoteHttpProblem(403, '別のページからは操作できません');
    }
  }

  static Future<Map<String, dynamic>> readJson(HttpRequest request) async {
    final bytes = <int>[];
    var oversized = false;
    await for (final chunk in request) {
      if (oversized || bytes.length + chunk.length > maximumRequestBytes) {
        oversized = true;
        continue;
      }
      bytes.addAll(chunk);
    }
    if (oversized) {
      throw const RemoteHttpProblem(413, '送信データが大きすぎます');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      throw const RemoteHttpProblem(400, 'JSONを読み取れません');
    }
    if (decoded is! Map) {
      throw const RemoteHttpProblem(400, '無効なJSONです');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static Future<void> html(HttpResponse response, String body) async {
    securityHeaders(response);
    response.headers.contentType = ContentType.html;
    response.write(body);
    await response.close();
  }

  static Future<void> json(
    HttpResponse response,
    Map<String, Object> body,
  ) async {
    securityHeaders(response);
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  static Future<void> problem(
    HttpRequest request,
    int status,
    String message,
  ) async {
    try {
      request.response.statusCode = status;
      await json(request.response, <String, Object>{'error': message});
    } on Object {
      // The peer may disconnect while DAM is processing a request.
    }
  }

  static void securityHeaders(HttpResponse response) {
    response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('X-Frame-Options', 'DENY')
      ..set('Referrer-Policy', 'no-referrer')
      ..set(
        'Content-Security-Policy',
        "default-src 'none'; style-src 'unsafe-inline'; "
            "script-src 'unsafe-inline'; connect-src 'self'; "
            "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      );
  }
}
