// Project: DAM for Windows Tools
// File: remote/remote_http.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:convert';
import 'dart:io';

/// 想定済みのHTTP状態と利用者向けメッセージを運ぶ例外です。
class RemoteHttpProblem implements Exception {
  /// ルーターから共通エラー応答へ渡す状態とメッセージを生成します。
  const RemoteHttpProblem(this.status, this.message);

  final int status;
  final String message;
}

/// Webリモコン共通の入力制限、Origin検証、応答ヘッダーを提供します。
abstract final class RemoteHttp {
  static const int maximumRequestBytes = 4096;

  /// Originヘッダーがある要求を、現在公開中のリモコンURLと完全一致で検証します。
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

  /// 本文を4KiBまで読み切り、トップレベルがオブジェクトのJSONだけを返します。
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

  /// セキュリティヘッダー付きのHTML応答を返して接続を閉じます。
  static Future<void> html(HttpResponse response, String body) async {
    securityHeaders(response);
    response.headers.contentType = ContentType.html;
    response.write(body);
    await response.close();
  }

  /// セキュリティヘッダー付きのJSON応答を返して接続を閉じます。
  static Future<void> json(
    HttpResponse response,
    Map<String, Object> body,
  ) async {
    securityHeaders(response);
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  /// APIエラーをJSONへ統一し、端末切断後の書き込み失敗は無視します。
  static Future<void> problem(
    HttpRequest request,
    int status,
    String message,
  ) async {
    try {
      request.response.statusCode = status;
      await json(request.response, <String, Object>{'error': message});
    } on Object {
      // DAM処理中にスマートフォンが切断した場合は、応答先がないため終了します。
    }
  }

  /// キャッシュ、MIME推測、埋め込み、参照元、外部資産を制限するヘッダーを設定します。
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
