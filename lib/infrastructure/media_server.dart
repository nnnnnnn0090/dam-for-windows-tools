// Project: DAM for Windows Tools
// File: media_server.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
import '../domain/app_settings.dart';
import '../domain/playback.dart';
import '../domain/tracks.dart';
import '../domain/value_objects.dart';
import 'app_paths.dart';
import 'media/hls_proxy.dart';
import 'media/hls_transcoder.dart';
import 'media/http_response_writer.dart';
import 'media/media_events.dart';
import 'media/media_job.dart';

export 'media/media_events.dart' show PlaybackStageHandler;
export 'media/media_job.dart' show MediaRegistration;

/// DAMへ安全なローカルHLS URLを渡し、公式中継と動画変換を振り分けます。
///
/// 上流URLやファイルパスをHTTPパスへ露出せず、セッショントークンとジョブIDで
/// 今回の起動に登録された動画だけをループバックへ配信します。
class LocalMediaServer {
  /// 配信先、状態通知、診断ログを受け取り、推測困難なセッショントークンを生成します。
  LocalMediaServer({
    required this.paths,
    required this.onStage,
    required this.onLog,
    this.listenPort = port,
  }) : sessionToken = _randomHex(32) {
    _proxy = HlsProxy(
      sessionToken: sessionToken,
      onStage: onStage,
      onLog: onLog,
    );
    _transcoder = HlsTranscoder(
      paths: paths,
      onStage: onStage,
      onLog: onLog,
      isStopping: () => _stopping,
    );
  }

  static const int port = AppConfig.mediaServerPort;
  static const Duration preparationTimeout = Duration(seconds: 90);
  static final RegExp _proxyId = RegExp(r'^[0-9a-f]{32}$');

  final AppPaths paths;
  final PlaybackStageHandler onStage;
  final DiagnosticLogHandler onLog;
  final int listenPort;
  final String sessionToken;
  final Map<String, MediaJob> _jobs = <String, MediaJob>{};
  final Map<String, String> _cache = <String, String>{};
  final Map<String, File> _manualSources = <String, File>{};

  late final HlsProxy _proxy;
  late final HlsTranscoder _transcoder;
  HttpServer? _server;
  bool _stopping = false;

  /// HTTPサーバーが待受中か返します。
  bool get isRunning => _server != null;

  /// OSが実際に割り当てたポートを返し、未起動時は設定値を返します。
  int get boundPort => _server?.port ?? listenPort;

  /// IPv4ループバックだけでHTTP待受を開始し、要求処理を非同期で継続します。
  Future<void> start() async {
    if (_server != null) return;
    _stopping = false;
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      listenPort,
      shared: false,
    );
    _server = server;
    unawaited(
      server.forEach(_handleRequest).catchError((Object error) {
        if (!_stopping) onLog('ローカル配信サーバーエラー: $error');
      }),
    );
    onLog(
      'ローカル配信サーバー起動: '
      'http://${AppConfig.loopbackHost}:${server.port}',
    );
  }

  /// 再生情報と設定からジョブを登録し、DAMへ返すローカルURLを生成します。
  ///
  /// 同一セッション・動画ID・補正値・ソース種別の成功ジョブは再利用し、公式URLは
  /// 再生のたびに最新候補へ更新します。
  Future<MediaRegistration> register(
    PlaybackDescriptor descriptor,
    AppSettings settings,
  ) async {
    if (_server == null) throw StateError('ローカル配信サーバーが停止しています');
    final videoId = normalizeVideoAssetId(descriptor.videoId);
    if (videoId.isEmpty) throw ArgumentError('動画IDが取得できません');
    final manual = _manualSources[videoId];
    if (manual == null && descriptor.upstreamUrls.isEmpty) {
      throw ArgumentError('利用可能な上流動画URLがありません');
    }
    if (manual != null && !await manual.exists()) {
      _manualSources.remove(videoId);
      throw StateError('GUIで指定した動画が見つかりません');
    }

    final skipMs = settings.effectiveSkipMs;
    final sourceKind = manual == null ? 'automatic' : 'manual';
    final cacheKey = sha256
        .convert(utf8.encode('$videoId\n$skipMs\n$sourceKind'))
        .toString();
    final existingId = _cache[cacheKey];
    final existing = existingId == null ? null : _jobs[existingId];
    if (existing != null && !existing.forceFallback) {
      if (manual == null) {
        existing
          ..highUrl = descriptor.highUrl ?? existing.highUrl
          ..lowUrl = descriptor.lowUrl ?? existing.lowUrl;
      }
      onStage(videoId, PlaybackStage.registered, 'セッション内の同一HLSを再利用します');
      return MediaRegistration(
        jobId: existing.id,
        localUrl: _localUrl(existing.id),
      );
    }
    if (existingId != null) _cache.remove(cacheKey);

    final jobId = _randomHex(16);
    final job = MediaJob(
      id: jobId,
      videoId: videoId,
      highUrl: descriptor.highUrl,
      lowUrl: descriptor.lowUrl,
      manualSource: manual,
      skipMs: skipMs,
      outputDirectory: Directory(p.join(paths.hlsDirectory.path, jobId)),
    );
    _jobs[jobId] = job;
    _cache[cacheKey] = jobId;
    onStage(videoId, PlaybackStage.registered, 'ローカルジョブを登録しました');
    return MediaRegistration(jobId: jobId, localUrl: _localUrl(jobId));
  }

  /// 検証済みの管理動画を指定IDへ割り当て、古いジョブキャッシュを無効化します。
  Future<void> setManualSource(String rawVideoId, File file) async {
    final videoId = normalizeVideoAssetId(rawVideoId);
    if (videoId.isEmpty) throw ArgumentError('動画IDが不正です');
    if (!await file.exists()) throw ArgumentError('選択した動画を読み込めません');
    _manualSources[videoId] = file;
    _cache.clear();
    onLog('[$videoId] 保存済みのGUI差し替え動画を登録しました');
  }

  /// 起動時に管理領域から見つかった差し替え動画を一括登録します。
  void restoreManualSources(Map<String, File> sources) {
    _manualSources
      ..clear()
      ..addAll(sources);
    if (sources.isNotEmpty) {
      onLog('保存済みの差し替え動画を${sources.length}件読み込みました');
    }
  }

  /// 指定IDの手動ソースを解除し、次回登録を公式動画へ戻します。
  void clearManualSource(String rawVideoId) {
    _manualSources.remove(normalizeVideoAssetId(rawVideoId));
    _cache.clear();
  }

  /// 指定IDへ差し替え動画が割り当てられているか返します。
  bool hasManualSource(String rawVideoId) =>
      _manualSources.containsKey(normalizeVideoAssetId(rawVideoId));

  /// HTTP受付、FFmpeg、上流クライアントを停止し、セッション内ジョブを破棄します。
  Future<void> stop() async {
    _stopping = true;
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
    await _transcoder.stop();
    _proxy.close();
    _jobs.clear();
    _cache.clear();
    _manualSources.clear();
  }

  /// HTTPメソッド、セッショントークン、ジョブ、資産IDを順に検証して配信します。
  ///
  /// 許可していない経路はすべて404とし、例外時もDAMへ応答を閉じて待機を残しません。
  Future<void> _handleRequest(HttpRequest request) async {
    try {
      request.response.headers
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('X-Content-Type-Options', 'nosniff');
      if (request.method != 'GET' && request.method != 'HEAD') {
        await HttpResponseWriter.error(
          request,
          HttpStatus.methodNotAllowed,
          'method not allowed',
        );
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length < 4 ||
          segments[0] != 'v1' ||
          segments[1] != sessionToken) {
        await HttpResponseWriter.error(
          request,
          HttpStatus.notFound,
          'not found',
        );
        return;
      }
      final job = _jobs[segments[2]];
      if (job == null) {
        await HttpResponseWriter.error(
          request,
          HttpStatus.notFound,
          'unknown job',
        );
        return;
      }
      if (segments.length == 4 && segments[3] == 'index.m3u8') {
        await _serveIndex(request, job);
      } else if (segments.length == 4 &&
          HlsTranscoder.segmentName.hasMatch(segments[3])) {
        await _serveSegment(request, job, segments[3]);
      } else if (segments.length == 5 &&
          segments[3] == 'proxy' &&
          _proxyId.hasMatch(segments[4])) {
        await _proxy.serveAsset(request, job, segments[4]);
      } else {
        await HttpResponseWriter.error(
          request,
          HttpStatus.notFound,
          'not found',
        );
      }
    } on Object catch (error, stackTrace) {
      onLog('HTTP処理失敗: $error\n$stackTrace');
      try {
        await HttpResponseWriter.error(
          request,
          HttpStatus.badGateway,
          'upstream failure',
        );
      } on Object {
        await request.response.close();
      }
    }
  }

  /// ジョブ条件に応じて公式HLS中継またはFFmpeg生成マニフェストを返します。
  ///
  /// 変換失敗・90秒超過・空ファイルでは公式配信へ退避し、ローカルエラーをDAMへ
  /// 直接返さないようにします。
  Future<void> _serveIndex(HttpRequest request, MediaJob job) async {
    onStage(job.videoId, PlaybackStage.manifestRequested, 'マニフェスト要求を受信');
    if (job.manualSource == null && job.skipMs == 0) {
      await _proxy.serveManifest(request, job, fallback: false);
      return;
    }
    onStage(job.videoId, PlaybackStage.preparing, '互換HLSを準備しています');
    _transcoder.ensureStarted(job);
    var complete = false;
    try {
      complete = await job.completed.future.timeout(preparationTimeout);
    } on TimeoutException {
      job.ffmpegProcess?.kill();
      job.forceFallback = true;
      if (!job.completed.isCompleted) job.completed.complete(false);
      onLog('[${job.videoId}] HLS準備が90秒を超えたため公式配信へ退避します');
    }
    if (!complete || job.forceFallback) {
      await _proxy.serveManifest(request, job, fallback: true);
      return;
    }
    final index = File(p.join(job.outputDirectory.path, 'index.m3u8'));
    if (!await index.exists() || await index.length() == 0) {
      job.forceFallback = true;
      await _proxy.serveManifest(request, job, fallback: true);
      return;
    }
    request.response.headers.contentType = ContentType(
      'application',
      'vnd.apple.mpegurl',
      charset: 'utf-8',
    );
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }
    await index.openRead().pipe(request.response);
    onStage(job.videoId, PlaybackStage.streaming, 'ローカルHLSを配信中');
  }

  /// 生成済みMPEG-TSを、出力ディレクトリ外への参照を拒否して配信します。
  Future<void> _serveSegment(
    HttpRequest request,
    MediaJob job,
    String name,
  ) async {
    final root = p.normalize(p.absolute(job.outputDirectory.path));
    final file = File(p.join(root, name));
    final resolved = p.normalize(p.absolute(file.path));
    if (!p.isWithin(root, resolved) || !await file.exists()) {
      await HttpResponseWriter.error(
        request,
        HttpStatus.notFound,
        'segment not ready',
      );
      return;
    }
    request.response.headers
      ..contentType = ContentType('video', 'mp2t')
      ..contentLength = await file.length();
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }
    await file.openRead().pipe(request.response);
    onStage(job.videoId, PlaybackStage.streaming, '動画セグメントを配信中');
  }

  /// セッショントークンとジョブIDだけを含むローカルマニフェストURLを組み立てます。
  String _localUrl(String jobId) =>
      'http://${AppConfig.loopbackHost}:'
      '$boundPort/v1/$sessionToken/$jobId/index.m3u8';

  /// HTTPパスの推測とジョブID衝突を防ぐ暗号学的乱数を生成します。
  static String _randomHex(int bytes) {
    final random = Random.secure();
    return List<int>.generate(
      bytes,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}
