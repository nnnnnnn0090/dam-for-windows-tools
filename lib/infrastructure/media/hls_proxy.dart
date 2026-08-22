// Project: DAM for Windows Tools
// File: media/hls_proxy.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/tracks.dart';
import 'hls_manifest_rewriter.dart';
import 'http_response_writer.dart';
import 'media_events.dart';
import 'media_job.dart';

/// 公式HLSを保存せずに中継し、high失敗時はlowへ退避します。
class HlsProxy {
  /// セッショントークンを持つ書換器と、上流HTTPクライアントを生成します。
  HlsProxy({
    required String sessionToken,
    required this.onStage,
    required this.onLog,
  }) : _rewriter = HlsManifestRewriter(sessionToken: sessionToken);

  static const int maximumManifestBytes = 4 * 1024 * 1024;

  final PlaybackStageHandler onStage;
  final DiagnosticLogHandler onLog;
  final HlsManifestRewriter _rewriter;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30)
    ..autoUncompress = true;

  /// 品質順に公式マニフェストを取得し、全URIをローカル中継経路へ変換します。
  ///
  /// 応答サイズを制限し、どの候補も使えない場合だけ502を返します。
  Future<void> serveManifest(
    HttpRequest request,
    MediaJob job, {
    required bool fallback,
  }) async {
    final candidates = <Uri>[
      if (job.highUrl != null) job.highUrl!,
      if (job.lowUrl != null && job.lowUrl != job.highUrl) job.lowUrl!,
    ];
    for (final uri in candidates) {
      try {
        final upstream = await _client
            .getUrl(uri)
            .timeout(const Duration(seconds: 20));
        upstream.followRedirects = true;
        final response = await upstream.close().timeout(
          const Duration(seconds: 20),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.drain<void>();
          continue;
        }
        final bytes = await _readLimited(response, maximumManifestBytes);
        final manifest = utf8.decode(bytes, allowMalformed: false);
        final effectiveUri = response.redirects.isEmpty
            ? uri
            : uri.resolveUri(response.redirects.last.location);
        await HttpResponseWriter.manifest(
          request,
          _rewriter.rewrite(job, effectiveUri, manifest),
        );
        onStage(
          job.videoId,
          fallback ? PlaybackStage.officialFallback : PlaybackStage.streaming,
          fallback ? '公式HLSへ退避しました' : '上流HLSを保存せず中継中',
        );
        return;
      } on Object catch (error) {
        onLog('[${job.videoId}] 公式HLS取得失敗: $error');
      }
    }
    onStage(job.videoId, PlaybackStage.failed, '公式配信への退避にも失敗しました');
    await HttpResponseWriter.error(
      request,
      HttpStatus.badGateway,
      'official stream unavailable',
    );
  }

  /// マニフェストで登録済みの資産だけを取得し、Rangeと内容種別を維持して返します。
  ///
  /// 資産自体が子マニフェストなら再度URIを書き換え、上流URLの直接露出を防ぎます。
  Future<void> serveAsset(
    HttpRequest request,
    MediaJob job,
    String assetId,
  ) async {
    final target = job.proxyAssets[assetId];
    if (target == null) {
      await HttpResponseWriter.error(
        request,
        HttpStatus.notFound,
        'unknown proxy asset',
      );
      return;
    }
    final upstream = await _client
        .getUrl(target)
        .timeout(const Duration(seconds: 20));
    upstream.followRedirects = true;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null && range.length <= 256) {
      upstream.headers.set(HttpHeaders.rangeHeader, range);
    }
    final response = await upstream.close().timeout(
      const Duration(seconds: 20),
    );
    if (response.statusCode < 200 || response.statusCode >= 400) {
      await response.drain<void>();
      await HttpResponseWriter.error(
        request,
        HttpStatus.badGateway,
        'proxy asset failed',
      );
      return;
    }
    final effectiveUri = response.redirects.isEmpty
        ? target
        : target.resolveUri(response.redirects.last.location);
    final contentType = response.headers.contentType;
    final isManifest =
        effectiveUri.path.toLowerCase().endsWith('.m3u8') ||
        contentType?.mimeType.contains('mpegurl') == true;
    request.response.statusCode = response.statusCode;
    if (isManifest) {
      final bytes = await _readLimited(response, maximumManifestBytes);
      await HttpResponseWriter.manifest(
        request,
        _rewriter.rewrite(
          job,
          effectiveUri,
          utf8.decode(bytes, allowMalformed: false),
        ),
      );
      return;
    }
    if (contentType != null) request.response.headers.contentType = contentType;
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    if (contentRange != null) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        contentRange,
      );
    }
    final length = response.contentLength;
    if (length >= 0) request.response.contentLength = length;
    if (request.method == 'HEAD') {
      await response.drain<void>();
      await request.response.close();
      return;
    }
    await response.pipe(request.response);
  }

  /// 保持中の上流HTTP接続を強制終了します。
  void close() => _client.close(force: true);

  /// ストリームを指定上限まで読み込み、巨大マニフェストは途中で拒否します。
  Future<List<int>> _readLimited(HttpClientResponse response, int limit) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response) {
      length += chunk.length;
      if (length > limit) throw StateError('上流マニフェストが上限を超えました');
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
