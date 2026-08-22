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
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
import '../domain/models.dart';
import 'app_paths.dart';

typedef PlaybackStageHandler = void Function(
  String videoId,
  PlaybackStage stage,
  String detail,
);

class MediaRegistration {
  const MediaRegistration({required this.jobId, required this.localUrl});

  final String jobId;
  final String localUrl;
}

class LocalMediaServer {
  LocalMediaServer({
    required this.paths,
    required this.onStage,
    required this.onLog,
    this.listenPort = port,
  });

  static const int port = AppConfig.mediaServerPort;
  static const Duration preparationTimeout = Duration(seconds: 90);
  static final RegExp _segmentName = RegExp(r'^segment_[0-9]{6}\.ts$');
  static final RegExp _proxyId = RegExp(r'^[0-9a-f]{32}$');

  final AppPaths paths;
  final PlaybackStageHandler onStage;
  final void Function(String message) onLog;
  final int listenPort;
  final HttpClient _upstreamClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30)
    ..autoUncompress = true;
  final Map<String, _MediaJob> _jobs = <String, _MediaJob>{};
  final Map<String, String> _cache = <String, String>{};
  final Map<String, File> _manualSources = <String, File>{};
  final Set<Process> _ffmpegProcesses = <Process>{};

  late final String sessionToken = _randomHex(32);
  HttpServer? _server;
  bool _stopping = false;

  bool get isRunning => _server != null;
  int get boundPort => _server?.port ?? listenPort;

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

  Future<MediaRegistration> register(
    PlaybackDescriptor descriptor,
    AppSettings settings,
  ) async {
    if (_server == null) throw StateError('ローカル配信サーバーが停止しています');
    final videoId = _normalizeId(descriptor.videoId);
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
    final output = Directory(p.join(paths.hlsDirectory.path, jobId));
    final job = _MediaJob(
      id: jobId,
      videoId: videoId,
      highUrl: descriptor.highUrl,
      lowUrl: descriptor.lowUrl,
      manualSource: manual,
      skipMs: skipMs,
      outputDirectory: output,
    );
    _jobs[jobId] = job;
    _cache[cacheKey] = jobId;
    onStage(videoId, PlaybackStage.registered, 'ローカルジョブを登録しました');
    return MediaRegistration(jobId: jobId, localUrl: _localUrl(jobId));
  }

  Future<void> setManualSource(String rawVideoId, File file) async {
    final videoId = _normalizeId(rawVideoId);
    if (videoId.isEmpty) throw ArgumentError('動画IDが不正です');
    if (!await file.exists()) throw ArgumentError('選択した動画を読み込めません');
    _manualSources[videoId] = file;
    _cache.clear();
    onLog('[$videoId] 保存済みのGUI差し替え動画を登録しました');
  }

  void restoreManualSources(Map<String, File> sources) {
    _manualSources
      ..clear()
      ..addAll(sources);
    if (sources.isNotEmpty) {
      onLog('保存済みの差し替え動画を${sources.length}件読み込みました');
    }
  }

  void clearManualSource(String rawVideoId) {
    final videoId = _normalizeId(rawVideoId);
    _manualSources.remove(videoId);
    _cache.clear();
  }

  bool hasManualSource(String rawVideoId) =>
      _manualSources.containsKey(_normalizeId(rawVideoId));

  Future<void> stop() async {
    _stopping = true;
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
    final processes = _ffmpegProcesses.toList(growable: false);
    for (final process in processes) {
      process.kill();
    }
    await Future.wait<void>(
      processes.map((process) async {
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
        }
      }),
    );
    _ffmpegProcesses.clear();
    _upstreamClient.close(force: true);
    _jobs.clear();
    _cache.clear();
    _manualSources.clear();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      request.response.headers
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('X-Content-Type-Options', 'nosniff');
      if (request.method != 'GET' && request.method != 'HEAD') {
        await _sendError(
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
        await _sendError(request, HttpStatus.notFound, 'not found');
        return;
      }
      final job = _jobs[segments[2]];
      if (job == null) {
        await _sendError(request, HttpStatus.notFound, 'unknown job');
        return;
      }
      if (segments.length == 4 && segments[3] == 'index.m3u8') {
        await _serveIndex(request, job);
        return;
      }
      if (segments.length == 4 && _segmentName.hasMatch(segments[3])) {
        await _serveSegment(request, job, segments[3]);
        return;
      }
      if (segments.length == 5 &&
          segments[3] == 'proxy' &&
          _proxyId.hasMatch(segments[4])) {
        await _serveProxyAsset(request, job, segments[4]);
        return;
      }
      await _sendError(request, HttpStatus.notFound, 'not found');
    } on Object catch (error, stackTrace) {
      onLog('HTTP処理失敗: $error\n$stackTrace');
      try {
        await _sendError(request, HttpStatus.badGateway, 'upstream failure');
      } on Object {
        await request.response.close();
      }
    }
  }

  Future<void> _serveIndex(HttpRequest request, _MediaJob job) async {
    onStage(job.videoId, PlaybackStage.manifestRequested, 'マニフェスト要求を受信');
    final needsTranscode = job.manualSource != null || job.skipMs > 0;
    if (!needsTranscode) {
      await _serveOfficialManifest(request, job, fallback: false);
      return;
    }
    onStage(job.videoId, PlaybackStage.preparing, '互換HLSを準備しています');
    _ensureTranscode(job);
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
      await _serveOfficialManifest(request, job, fallback: true);
      return;
    }
    final index = File(p.join(job.outputDirectory.path, 'index.m3u8'));
    if (!await index.exists() || await index.length() == 0) {
      job.forceFallback = true;
      await _serveOfficialManifest(request, job, fallback: true);
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

  Future<void> _serveSegment(
    HttpRequest request,
    _MediaJob job,
    String name,
  ) async {
    if (!_segmentName.hasMatch(name)) {
      await _sendError(request, HttpStatus.notFound, 'invalid segment');
      return;
    }
    final root = p.normalize(p.absolute(job.outputDirectory.path));
    final file = File(p.join(root, name));
    final resolved = p.normalize(p.absolute(file.path));
    if (!p.isWithin(root, resolved) || !await file.exists()) {
      await _sendError(request, HttpStatus.notFound, 'segment not ready');
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

  Future<void> _serveOfficialManifest(
    HttpRequest request,
    _MediaJob job, {
    required bool fallback,
  }) async {
    final candidates = <Uri>[
      if (job.highUrl != null) job.highUrl!,
      if (job.lowUrl != null && job.lowUrl != job.highUrl) job.lowUrl!,
    ];
    for (final uri in candidates) {
      try {
        final upstream = await _upstreamClient
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
        final bytes = await _readLimited(response, 4 * 1024 * 1024);
        final manifest = utf8.decode(bytes, allowMalformed: false);
        final effectiveUri = response.redirects.isEmpty
            ? uri
            : uri.resolveUri(response.redirects.last.location);
        final rewritten = _rewriteManifest(job, effectiveUri, manifest);
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
          charset: 'utf-8',
        );
        final output = utf8.encode(rewritten);
        request.response.contentLength = output.length;
        if (request.method != 'HEAD') request.response.add(output);
        onStage(
          job.videoId,
          fallback ? PlaybackStage.officialFallback : PlaybackStage.streaming,
          fallback ? '公式HLSへ退避しました' : '上流HLSを保存せず中継中',
        );
        await request.response.close();
        return;
      } on Object catch (error) {
        onLog('[${job.videoId}] 公式HLS取得失敗: $error');
      }
    }
    onStage(job.videoId, PlaybackStage.failed, '公式配信への退避にも失敗しました');
    await _sendError(
      request,
      HttpStatus.badGateway,
      'official stream unavailable',
    );
  }

  Future<void> _serveProxyAsset(
    HttpRequest request,
    _MediaJob job,
    String assetId,
  ) async {
    final target = job.proxyAssets[assetId];
    if (target == null) {
      await _sendError(request, HttpStatus.notFound, 'unknown proxy asset');
      return;
    }
    final upstream = await _upstreamClient
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
      await _sendError(request, HttpStatus.badGateway, 'proxy asset failed');
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
      final bytes = await _readLimited(response, 4 * 1024 * 1024);
      final rewritten = _rewriteManifest(
        job,
        effectiveUri,
        utf8.decode(bytes, allowMalformed: false),
      );
      final output = utf8.encode(rewritten);
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
      request.response.contentLength = output.length;
      if (request.method != 'HEAD') request.response.add(output);
      await request.response.close();
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

  String _rewriteManifest(_MediaJob job, Uri baseUri, String source) {
    String localize(String raw) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed.length > 8192) return raw;
      final resolved = baseUri.resolve(trimmed);
      if (resolved.scheme != 'http' && resolved.scheme != 'https') return raw;
      final id = sha256
          .convert(utf8.encode(resolved.toString()))
          .toString()
          .substring(0, 32);
      job.proxyAssets[id] = resolved;
      return '/v1/$sessionToken/${job.id}/proxy/$id';
    }

    final uriAttribute = RegExp(r'URI="([^"]+)"');
    return source
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) {
          if (line.isEmpty) return line;
          if (!line.startsWith('#')) return localize(line);
          return line.replaceAllMapped(uriAttribute, (match) {
            return 'URI="${localize(match.group(1)!)}"';
          });
        })
        .join('\n');
  }

  void _ensureTranscode(_MediaJob job) {
    if (job.transcodeStarted) return;
    job.transcodeStarted = true;
    unawaited(_runTranscode(job));
  }

  Future<void> _runTranscode(_MediaJob job) async {
    final sources = <String>[
      if (job.manualSource != null) job.manualSource!.path,
      if (job.manualSource == null && job.highUrl != null)
        job.highUrl.toString(),
      if (job.manualSource == null &&
          job.lowUrl != null &&
          job.lowUrl != job.highUrl)
        job.lowUrl.toString(),
    ];
    for (var index = 0; index < sources.length && !_stopping; index += 1) {
      if (job.forceFallback) break;
      final source = sources[index];
      try {
        if (await job.outputDirectory.exists()) {
          await job.outputDirectory.delete(recursive: true);
        }
        await job.outputDirectory.create(recursive: true);
        job.firstSegmentsReported = false;
        final result = await _runTranscodeAttempt(job, source);
        if (result) {
          if (!job.completed.isCompleted) job.completed.complete(true);
          onStage(job.videoId, PlaybackStage.preparing, '全尺HLSの準備完了');
          return;
        }
        if (index + 1 < sources.length) {
          onLog('[${job.videoId}] high bitrate失敗。low bitrateで再試行します');
        }
      } on Object catch (error) {
        onLog('[${job.videoId}] FFmpeg起動失敗: $error');
      }
    }
    job.forceFallback = true;
    if (!job.completed.isCompleted) job.completed.complete(false);
    onStage(job.videoId, PlaybackStage.officialFallback, 'HLS生成失敗のため公式へ退避');
  }

  Future<bool> _runTranscodeAttempt(_MediaJob job, String source) async {
    final segmentPattern = p.join(job.outputDirectory.path, 'segment_%06d.ts');
    final indexPath = p.join(job.outputDirectory.path, 'index.m3u8');
    final args = <String>[
      '-nostdin',
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      '-fflags',
      '+genpts',
      '-avoid_negative_ts',
      'make_zero',
      if (source.startsWith('http://') ||
          source.startsWith('https://')) ...<String>['-rw_timeout', '15000000'],
      '-i',
      source,
      if (job.skipMs > 0) ...<String>[
        '-ss',
        (job.skipMs / 1000).toStringAsFixed(6),
      ],
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      '-c:v',
      'libx264',
      '-vf',
      'scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2',
      '-preset',
      'ultrafast',
      '-crf',
      '22',
      '-profile:v',
      'baseline',
      '-level:v',
      '3.1',
      '-pix_fmt',
      'yuv420p',
      '-r',
      '30000/1001',
      '-g',
      '60',
      '-keyint_min',
      '60',
      '-sc_threshold',
      '0',
      '-force_key_frames',
      'expr:gte(t,n_forced*2)',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      '-ar',
      '48000',
      '-af',
      'aresample=async=1:first_pts=0',
      '-f',
      'hls',
      '-hls_time',
      '2',
      '-hls_list_size',
      '0',
      '-hls_playlist_type',
      'event',
      '-hls_flags',
      'independent_segments+temp_file',
      '-hls_segment_type',
      'mpegts',
      '-hls_segment_filename',
      segmentPattern,
      indexPath,
    ];
    final process = await Process.start(
      paths.ffmpegExecutable,
      args,
      runInShell: paths.ffmpegExecutable == 'ffmpeg',
    );
    job.ffmpegProcess = process;
    _ffmpegProcesses.add(process);
    final errors = <String>[];
    final stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.isNotEmpty) {
            errors.add(line);
            if (errors.length > 20) errors.removeAt(0);
          }
        });
    unawaited(process.stdout.drain<void>());
    final exit = process.exitCode;
    while (!_stopping) {
      final outcome = await Future.any<Object>(<Future<Object>>[
        exit.then<Object>((code) => code),
        Future<Object>.delayed(const Duration(milliseconds: 100), () => 'tick'),
      ]);
      if (!job.firstSegmentsReported &&
          await _hasPlayableOutput(job.outputDirectory)) {
        job.firstSegmentsReported = true;
        onStage(job.videoId, PlaybackStage.preparing, '先頭2セグメント生成済み・全尺を生成中');
      }
      if (outcome is int) {
        await stderrSubscription.cancel();
        _ffmpegProcesses.remove(process);
        job.ffmpegProcess = null;
        final completeOutput =
            outcome == 0 && await _hasCompleteOutput(job.outputDirectory);
        if (!completeOutput && errors.isNotEmpty) {
          onLog('[${job.videoId}] ${errors.join(' | ')}');
        }
        return completeOutput;
      }
    }
    process.kill();
    final exitCode = await exit;
    await stderrSubscription.cancel();
    _ffmpegProcesses.remove(process);
    job.ffmpegProcess = null;
    if (job.firstSegmentsReported && exitCode != 0) {
      onLog('[${job.videoId}] HLS生成中にFFmpegが異常終了しました (exit $exitCode)');
    }
    return false;
  }

  Future<bool> _hasPlayableOutput(Directory output) async {
    final index = File(p.join(output.path, 'index.m3u8'));
    if (!await index.exists() || await index.length() == 0) return false;
    var segments = 0;
    await for (final entity in output.list(followLinks: false)) {
      if (entity is File && _segmentName.hasMatch(p.basename(entity.path))) {
        if (await entity.length() > 0) segments += 1;
      }
      if (segments >= 2) return true;
    }
    return false;
  }

  Future<bool> _hasCompleteOutput(Directory output) async {
    if (!await _hasPlayableOutput(output)) return false;
    final index = File(p.join(output.path, 'index.m3u8'));
    try {
      final manifest = await index.readAsString();
      return manifest.contains('#EXT-X-ENDLIST');
    } on FileSystemException {
      return false;
    }
  }

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

  Future<void> _sendError(HttpRequest request, int status, String text) async {
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

  String _localUrl(String jobId) =>
      'http://${AppConfig.loopbackHost}:'
      '$boundPort/v1/$sessionToken/$jobId/index.m3u8';

  static String _normalizeId(String value) {
    return normalizeVideoAssetId(value);
  }

  static String _randomHex(int bytes) {
    final random = Random.secure();
    return List<int>.generate(
      bytes,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}

class _MediaJob {
  _MediaJob({
    required this.id,
    required this.videoId,
    required this.highUrl,
    required this.lowUrl,
    required this.manualSource,
    required this.skipMs,
    required this.outputDirectory,
  });

  final String id;
  final String videoId;
  Uri? highUrl;
  Uri? lowUrl;
  final File? manualSource;
  final int skipMs;
  final Directory outputDirectory;
  final Completer<bool> completed = Completer<bool>();
  final Map<String, Uri> proxyAssets = <String, Uri>{};
  bool transcodeStarted = false;
  bool firstSegmentsReported = false;
  bool forceFallback = false;
  Process? ffmpegProcess;
}
