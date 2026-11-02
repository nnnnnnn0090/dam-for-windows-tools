import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../domain/tracks.dart';
import '../random_token.dart';
import 'manifest_rewriter.dart';
import 'transcoder.dart';

typedef StageHandler = void Function(
  String videoId,
  PlaybackStage stage,
  String detail,
);

/// 127.0.0.1だけで待ち受け、DAMへ差し替え動画または中継した公式HLSを返します。
///
/// URLは `/v1/<セッショントークン>/<ジョブID>/...` で、トークンを知らない
/// ローカルの他プロセスからは利用できません。
class MediaServer {
  MediaServer({
    required this.port,
    required this.hlsDirectory,
    required this.ffmpeg,
    required this.onStage,
    required this.onLog,
    this.progressive = false,
  });

  /// 同時に保持するジョブ数です。超えたら最も古いものからFFmpegを止めて消します。
  static const int maximumJobs = 6;

  /// 変換完了を待つ上限です。超えたらその回は公式へ退避し、変換は続けます。
  static const Duration preparationTimeout = Duration(seconds: 90);
  static const int maximumManifestBytes = 4 * 1024 * 1024;
  static final RegExp _proxyId = RegExp(r'^[0-9a-f]{32}$');

  final int port;
  final Directory hlsDirectory;
  final String ffmpeg;
  final StageHandler onStage;
  final void Function(String message) onLog;

  /// `true` なら先頭2セグメント完成時点で生成途中のプレイリストを返します。
  /// DAMの動画再生が途中のプレイリストを正しく扱うかは実機確認が必要なため、
  /// 既定はv1同様に全尺完成を待ちます。
  final bool progressive;

  final String _token = randomHex(32);
  final Map<String, _Job> _jobs = <String, _Job>{}; // 挿入順 = 古い順
  final Map<String, File> _manualSources = <String, File>{};
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30)
    ..autoUncompress = true;
  HttpServer? _server;

  bool get isRunning => _server != null;

  /// ポートを確保できなければ [SocketException] を投げます。
  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object error) => onLog('ローカル配信サーバーエラー: $error'),
    );
    onLog('ローカル配信サーバー起動: http://127.0.0.1:$port');
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    await Future.wait(
      _jobs.values.map(
        (job) => job.transcode?.cancel() ?? Future<void>.value(),
      ),
    );
    _jobs.clear();
    _client.close(force: true);
  }

  void setManualSources(Map<String, File> sources) {
    _manualSources
      ..clear()
      ..addAll(sources);
  }

  bool hasManualSource(String videoId) => _manualSources.containsKey(videoId);

  /// 指定動画のジョブを止めて消します。差し替え動画の変更・解除の前に呼びます。
  Future<void> forget(String videoId) async {
    final doomed = _jobs.entries
        .where((e) => e.value.videoId == videoId)
        .toList();
    for (final entry in doomed) {
      _jobs.remove(entry.key);
      await _dispose(entry.value);
    }
  }

  Future<void> setManualSource(String videoId, File? file) async {
    await forget(videoId);
    if (file == null) {
      _manualSources.remove(videoId);
    } else {
      _manualSources[videoId] = file;
    }
  }

  /// 再生要求を登録し、DAMへ渡すローカルURLを返します。
  ///
  /// 途中に `await` を挟まないため、同じ曲の同時登録は1つのジョブにまとまります。
  String register(PlaybackDescriptor descriptor, {required int skipMs}) {
    if (_server == null) throw StateError('ローカル配信サーバーが停止しています');
    final videoId = descriptor.videoId;
    if (videoId.isEmpty) throw ArgumentError('動画IDがありません');
    final manual = _manualSources[videoId];
    if (manual != null && !manual.existsSync()) {
      _manualSources.remove(videoId);
      throw StateError('差し替え動画が見つかりません: ${manual.path}');
    }
    if (manual == null && descriptor.upstreamUrls.isEmpty) {
      throw ArgumentError('上流動画URLがありません');
    }
    final key = '$videoId\n$skipMs\n${manual?.path ?? ''}';
    var job = _jobs.remove(key);
    if (job != null) {
      // 公式への退避に使う上流URLは、毎回新しいものへ更新します。
      job.upstream = descriptor.upstreamUrls.isEmpty
          ? job.upstream
          : descriptor.upstreamUrls;
      onStage(videoId, PlaybackStage.registered, 'セッション内の同一HLSを再利用します');
    } else {
      job = _Job(
        id: randomHex(16),
        videoId: videoId,
        upstream: descriptor.upstreamUrls,
        manual: manual,
        skipMs: skipMs,
      );
      onStage(videoId, PlaybackStage.registered, 'ローカルジョブを登録しました');
    }
    _jobs[key] = job; // 末尾へ移動し、最近使ったものとして扱います。
    _evict();
    return 'http://127.0.0.1:$port/v1/$_token/${job.id}/index.m3u8';
  }

  void _evict() {
    while (_jobs.length > maximumJobs) {
      final oldest = _jobs.keys.first;
      unawaited(_dispose(_jobs.remove(oldest)!));
    }
  }

  Future<void> _dispose(_Job job) async {
    await job.transcode?.cancel();
    final directory = job.transcode?.outputDirectory;
    if (directory != null && await directory.exists()) {
      await directory
          .delete(recursive: true)
          .catchError((Object _) => directory);
    }
  }

  _Job? _jobById(String id) {
    for (final job in _jobs.values) {
      if (job.id == id) return job;
    }
    return null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        return await _error(
          response,
          HttpStatus.methodNotAllowed,
          'method not allowed',
        );
      }
      final segments = request.uri.pathSegments;
      if (segments.length < 4 || segments[0] != 'v1' || segments[1] != _token) {
        return await _error(response, HttpStatus.notFound, 'not found');
      }
      final job = _jobById(segments[2]);
      if (job == null) {
        return await _error(response, HttpStatus.notFound, 'unknown job');
      }
      final name = segments[3];
      if (segments.length == 4 && name == Transcode.indexName) {
        await _serveIndex(request, job);
      } else if (segments.length == 4 && Transcode.segmentName.hasMatch(name)) {
        await _serveSegment(request, job, name);
      } else if (segments.length == 5 &&
          name == 'proxy' &&
          _proxyId.hasMatch(segments[4])) {
        await _serveProxied(request, job, segments[4]);
      } else {
        await _error(response, HttpStatus.notFound, 'not found');
      }
    } on Object catch (error) {
      onLog('[配信] ${request.uri.pathSegments.lastOrNull ?? ''}: $error');
      await _abort(response);
    }
  }

  Future<void> _serveIndex(HttpRequest request, _Job job) async {
    onStage(job.videoId, PlaybackStage.manifestRequested, 'マニフェスト要求を受信');
    if (job.manual == null && job.skipMs == 0) {
      return _serveUpstreamManifest(request, job, fallback: false);
    }
    final transcode = job.transcode ??= _startTranscode(job);
    onStage(job.videoId, PlaybackStage.preparing, '互換HLSを準備しています');
    final ready = progressive
        ? Future.any(<Future<bool>>[
            transcode.playable.then((_) => true),
            transcode.finished,
          ])
        : transcode.finished;
    final ok = await ready.timeout(preparationTimeout, onTimeout: () => false);
    if (!ok) {
      if (!transcode.isFinished) {
        onLog(
          '[${job.videoId}] HLS準備が${preparationTimeout.inSeconds}秒を超えたため今回は公式配信へ退避します（変換は継続）',
        );
      }
      return _serveUpstreamManifest(request, job, fallback: true);
    }
    request.response.headers.contentType = _mpegUrl;
    if (request.method == 'HEAD') return request.response.close();
    await request.response.addStream(transcode.index.openRead());
    await request.response.close();
    onStage(job.videoId, PlaybackStage.streaming, 'ローカルHLSを配信中');
  }

  Transcode _startTranscode(_Job job) {
    final transcode = Transcode(
      ffmpeg: ffmpeg,
      sources: job.manual != null
          ? <String>[job.manual!.path]
          : <String>[for (final uri in job.upstream) uri.toString()],
      skipMs: job.skipMs,
      outputDirectory: Directory(p.join(hlsDirectory.path, job.id)),
      onLog: (message) => onLog('[${job.videoId}] $message'),
    )..start();
    unawaited(
      transcode.playable.then((_) {
        onStage(job.videoId, PlaybackStage.preparing, '先頭セグメント生成済み');
      }),
    );
    unawaited(
      transcode.finished.then((ok) {
        if (!ok) {
          onStage(
            job.videoId,
            PlaybackStage.officialFallback,
            'HLS生成に失敗したため公式へ退避します',
          );
        }
      }),
    );
    return transcode;
  }

  Future<void> _serveSegment(HttpRequest request, _Job job, String name) async {
    final transcode = job.transcode;
    final file = transcode == null
        ? null
        : File(p.join(transcode.outputDirectory.path, name));
    if (file == null || !await file.exists()) {
      return _error(request.response, HttpStatus.notFound, 'segment not ready');
    }
    request.response.headers
      ..contentType = ContentType('video', 'mp2t')
      ..contentLength = await file.length();
    if (request.method == 'HEAD') return request.response.close();
    await request.response.addStream(file.openRead());
    await request.response.close();
    onStage(job.videoId, PlaybackStage.streaming, '動画セグメントを配信中');
  }

  Future<void> _serveUpstreamManifest(
    HttpRequest request,
    _Job job, {
    required bool fallback,
  }) async {
    for (final uri in job.upstream) {
      try {
        final upstream = await _fetch(uri);
        if (upstream.response.statusCode ~/ 100 != 2) {
          await upstream.response.drain<void>();
          continue;
        }
        final manifest = utf8.decode(await _readLimited(upstream.response));
        await _sendManifest(request, job, upstream.effectiveUri, manifest);
        onStage(
          job.videoId,
          fallback ? PlaybackStage.officialFallback : PlaybackStage.streaming,
          fallback ? '公式HLSへ退避しました' : '上流HLSを保存せず中継中',
        );
        return;
      } on Object catch (error) {
        onLog('[${job.videoId}] 公式HLSの取得に失敗しました: $error');
      }
    }
    onStage(job.videoId, PlaybackStage.failed, '公式配信の取得にも失敗しました');
    await _error(
      request.response,
      HttpStatus.badGateway,
      'official stream unavailable',
    );
  }

  Future<void> _serveProxied(HttpRequest request, _Job job, String id) async {
    final target = job.proxyAssets[id];
    if (target == null) {
      return _error(
        request.response,
        HttpStatus.notFound,
        'unknown proxy asset',
      );
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final upstream = await _fetch(
      target,
      range: range != null && range.length <= 256 ? range : null,
    );
    final source = upstream.response;
    if (source.statusCode < 200 || source.statusCode >= 400) {
      await source.drain<void>();
      return _error(
        request.response,
        HttpStatus.badGateway,
        'proxy asset failed',
      );
    }
    final contentType = source.headers.contentType;
    if (upstream.effectiveUri.path.toLowerCase().endsWith('.m3u8') ||
        (contentType?.mimeType.contains('mpegurl') ?? false)) {
      return _sendManifest(
        request,
        job,
        upstream.effectiveUri,
        utf8.decode(await _readLimited(source)),
      );
    }
    final response = request.response..statusCode = source.statusCode;
    if (contentType != null) response.headers.contentType = contentType;
    final contentRange = source.headers.value(HttpHeaders.contentRangeHeader);
    if (contentRange != null) {
      response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
    }
    if (source.contentLength >= 0) {
      response.contentLength = source.contentLength;
    }
    if (request.method == 'HEAD') {
      await source.drain<void>();
      return response.close();
    }
    // 視聴側が切断したら上流の受信も打ち切ります。
    await response.addStream(source.timeout(const Duration(seconds: 30)));
    await response.close();
  }

  Future<void> _sendManifest(
    HttpRequest request,
    _Job job,
    Uri base,
    String manifest,
  ) async {
    final body = rewriteManifest(
      source: manifest,
      baseUri: base,
      proxyPrefix: '/v1/$_token/${job.id}/proxy/',
      register: job.registerProxy,
    );
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = _mpegUrl;
    final bytes = utf8.encode(body);
    response.contentLength = bytes.length;
    if (request.method != 'HEAD') response.add(bytes);
    await response.close();
  }

  Future<({HttpClientResponse response, Uri effectiveUri})> _fetch(
    Uri uri, {
    String? range,
  }) async {
    final request = await _client
        .getUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.followRedirects = true;
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close().timeout(const Duration(seconds: 20));
    final effective = response.redirects.isEmpty
        ? uri
        : uri.resolveUri(response.redirects.last.location);
    return (response: response, effectiveUri: effective);
  }

  static Future<Uint8List> _readLimited(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      builder.add(chunk);
      if (builder.length > maximumManifestBytes) {
        throw const FormatException('上流マニフェストが上限を超えました');
      }
    }
    return builder.takeBytes();
  }

  static final ContentType _mpegUrl = ContentType(
    'application',
    'vnd.apple.mpegurl',
    charset: 'utf-8',
  );

  static Future<void> _error(
    HttpResponse response,
    int status,
    String message,
  ) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.text;
    response.write(message);
    await response.close();
  }

  /// 応答ヘッダー送信後の失敗は状態コードを変えられないため、接続を閉じるだけにします。
  static Future<void> _abort(HttpResponse response) async {
    try {
      response.statusCode = HttpStatus.badGateway;
    } on StateError {
      // 既に送信済みです。
    }
    try {
      await response.close();
    } on Object {
      // 既に切断済みです。
    }
  }
}

class _Job {
  _Job({
    required this.id,
    required this.videoId,
    required this.upstream,
    required this.manual,
    required this.skipMs,
  });

  static const int _maximumProxyAssets = 4096;

  final String id;
  final String videoId;
  List<Uri> upstream;
  final File? manual;
  final int skipMs;
  Transcode? transcode;
  final Map<String, Uri> proxyAssets = <String, Uri>{};

  void registerProxy(String id, Uri target) {
    proxyAssets.remove(id);
    proxyAssets[id] = target;
    while (proxyAssets.length > _maximumProxyAssets) {
      proxyAssets.remove(proxyAssets.keys.first);
    }
  }
}
