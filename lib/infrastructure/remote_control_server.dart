// Project: DAM for Windows Tools
// File: remote_control_server.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../config/app_config.dart';
import '../domain/models.dart';
import 'remote_page_provider.dart';

typedef RemoteSongSearch = Future<List<RemoteSong>> Function(
  String query,
  RemoteSearchMode mode,
);
typedef RemoteSongReservation = Future<RemoteReservationResult> Function(
  String token,
  RemoteReservationOptions options,
);
typedef RemoteSongDetailReader = Future<RemoteSongDetail> Function(
  String token,
);
typedef RemoteFavoriteCommand = Future<RemoteFavoriteResult> Function(
  String token,
  bool favorite,
);
typedef RemoteStateReader = Future<RemoteControlState> Function();
typedef RemotePlaybackCommand = Future<RemoteControlState> Function(
  String action,
);
typedef RemoteQueueReader = Future<List<RemoteQueueEntry>> Function();
typedef RemoteQueueCommand = Future<List<RemoteQueueEntry>> Function(
  String action,
  String token,
);
typedef RemoteHistoryReader = Future<List<RemoteSong>> Function();

class RemoteControlServer {
  RemoteControlServer({
    required this.search,
    required this.readSongDetail,
    required this.reserve,
    required this.favorite,
    required this.readState,
    required this.controlPlayback,
    required this.readQueue,
    required this.controlQueue,
    required this.readHistory,
    required this.onLog,
    this.port = AppConfig.remoteServerPort,
    InternetAddress? bindAddress,
    this.advertisedAddress,
    String? sessionToken,
    RemotePageProvider? pageProvider,
  }) : _bindAddress = bindAddress ?? InternetAddress.anyIPv4,
       _sessionToken = sessionToken ?? _randomHex(32),
       _pageProvider = pageProvider ?? RemotePageProvider();

  final RemoteSongSearch search;
  final RemoteSongDetailReader readSongDetail;
  final RemoteSongReservation reserve;
  final RemoteFavoriteCommand favorite;
  final RemoteStateReader readState;
  final RemotePlaybackCommand controlPlayback;
  final RemoteQueueReader readQueue;
  final RemoteQueueCommand controlQueue;
  final RemoteHistoryReader readHistory;
  final void Function(String message) onLog;
  final int port;
  final InternetAddress _bindAddress;
  final String? advertisedAddress;
  final String _sessionToken;
  final RemotePageProvider _pageProvider;
  final Map<String, List<int>> _requestTimes = <String, List<int>>{};

  HttpServer? _server;
  String? _url;
  int _activeRequests = 0;

  bool get isRunning => _server != null;
  String? get url => _url;

  Future<void> start() async {
    if (_server != null) return;
    await _pageProvider.load();
    final advertised =
        advertisedAddress ??
        await _findPreferredLanAddress() ??
        AppConfig.loopbackHost;
    final server = await HttpServer.bind(
      _bindAddress,
      port,
      shared: false,
      v6Only: false,
    );
    server.idleTimeout = const Duration(seconds: 15);
    _server = server;
    _url = Uri(
      scheme: 'http',
      host: advertised,
      port: server.port,
      path: '/$_sessionToken/',
    ).toString();
    server.listen(
      (request) => unawaited(_serve(request)),
      onError: (Object error) => onLog('リモコンサーバー: $error'),
    );
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _url = null;
    _requestTimes.clear();
    if (server != null) await server.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    if (_activeRequests >= 8) {
      await _problem(request, 503, '処理が混み合っています');
      return;
    }
    _activeRequests++;
    try {
      if (!_isPrivateClient(request.connectionInfo?.remoteAddress)) {
        await _problem(request, 403, 'この端末からは接続できません');
        return;
      }
      if (!_consumeRate(request.connectionInfo?.remoteAddress.address ?? '?')) {
        await _problem(request, 429, '操作が多すぎます。少し待ってください');
        return;
      }

      final pagePath = '/$_sessionToken/';
      final searchPath = '${pagePath}api/search';
      final detailPath = '${pagePath}api/detail';
      final reservePath = '${pagePath}api/reserve';
      final favoritePath = '${pagePath}api/favorite';
      final statePath = '${pagePath}api/state';
      final controlPath = '${pagePath}api/control';
      final queuePath = '${pagePath}api/queue';
      final queueActionPath = '${pagePath}api/queue-action';
      final historyPath = '${pagePath}api/history';
      final path = request.uri.path;
      if (request.method == 'GET' && path == pagePath) {
        await _html(request.response, await _pageProvider.load());
        return;
      }
      if (request.method != 'POST' ||
          !<String>{
            searchPath,
            detailPath,
            reservePath,
            favoritePath,
            statePath,
            controlPath,
            queuePath,
            queueActionPath,
            historyPath,
          }.contains(path)) {
        await _problem(request, 404, '見つかりません');
        return;
      }
      _verifySameOrigin(request);
      final contentType = request.headers.contentType;
      if (contentType?.mimeType != 'application/json') {
        throw const _HttpProblem(415, 'JSON形式で送信してください');
      }
      final body = await _readJson(request);
      if (path == searchPath) {
        final query = body['query'];
        if (query is! String) {
          throw const _HttpProblem(400, '検索語を入力してください');
        }
        final modeName = body['mode']?.toString() ?? 'keyword';
        final mode = switch (modeName) {
          'keyword' => RemoteSearchMode.keyword,
          'title' => RemoteSearchMode.title,
          'artist' => RemoteSearchMode.artist,
          'ranking' => RemoteSearchMode.ranking,
          'new' => RemoteSearchMode.newReleases,
          'favorites' => RemoteSearchMode.favorites,
          _ => throw const _HttpProblem(400, '無効な検索種別です'),
        };
        final songs = await search(query, mode);
        await _json(request.response, <String, Object>{
          'songs': songs.map((song) => song.toJson()).toList(growable: false),
        });
      } else if (path == detailPath) {
        final token = body['token'];
        if (token is! String) {
          throw const _HttpProblem(400, '無効な検索結果です');
        }
        final detail = await readSongDetail(token);
        await _json(request.response, <String, Object>{
          'detail': detail.toJson(),
        });
      } else if (path == reservePath) {
        final token = body['token'];
        if (token is! String) {
          throw const _HttpProblem(400, '無効な検索結果です');
        }
        final mode = body['mode'];
        if (mode != null &&
            mode != 'normal' &&
            mode != 'cutIn' &&
            mode != 'originalKey') {
          throw const _HttpProblem(400, '無効な予約方法です');
        }
        final key = body['key'];
        if (key is! num || key.toInt() < -7 || key.toInt() > 7) {
          throw const _HttpProblem(400, 'キーは-7～+7で指定してください');
        }
        final playTypeName = body['playType']?.toString() ?? 'standard';
        final playType = switch (playTypeName) {
          'standard' => RemotePlayType.standard,
          'guideVocal' => RemotePlayType.guideVocal,
          'artistVideo' => RemotePlayType.artistVideo,
          _ => throw const _HttpProblem(400, '無効な演奏タイプです'),
        };
        final reservationMode = switch (mode) {
          'cutIn' => RemoteReservationMode.cutIn,
          'originalKey' => RemoteReservationMode.originalKey,
          _ => RemoteReservationMode.normal,
        };
        final result = await reserve(
          token,
          RemoteReservationOptions(
            mode: reservationMode,
            key: key.toInt(),
            scoring: body['scoring'] == true,
            playType: playType,
          ),
        );
        await _json(request.response, <String, Object>{
          'accepted': result.accepted,
          'message': result.message,
          'videoId': result.videoId,
          'artist': result.artist,
          'title': result.title,
        });
      } else if (path == favoritePath) {
        final token = body['token'];
        final enabled = body['favorite'];
        if (token is! String || enabled is! bool) {
          throw const _HttpProblem(400, '無効なお気に入り操作です');
        }
        final result = await favorite(token, enabled);
        await _json(request.response, <String, Object>{
          'accepted': result.accepted,
          'favorite': result.favorite,
          'message': result.message,
        });
      } else if (path == statePath) {
        final state = await readState();
        await _json(request.response, state.toJson());
      } else if (path == controlPath) {
        final action = body['action'];
        if (action is! String) {
          throw const _HttpProblem(400, '無効な再生操作です');
        }
        final state = await controlPlayback(action);
        await _json(request.response, state.toJson());
      } else if (path == queuePath) {
        final rows = await readQueue();
        await _json(request.response, <String, Object>{
          'rows': rows.map((row) => row.toJson()).toList(growable: false),
        });
      } else if (path == historyPath) {
        final rows = await readHistory();
        await _json(request.response, <String, Object>{
          'rows': rows.map((row) => row.toJson()).toList(growable: false),
        });
      } else {
        final action = body['action'];
        final token = body['token'];
        if (action is! String || token is! String) {
          throw const _HttpProblem(400, '無効な予約操作です');
        }
        final rows = await controlQueue(action, token);
        await _json(request.response, <String, Object>{
          'rows': rows.map((row) => row.toJson()).toList(growable: false),
        });
      }
    } on _HttpProblem catch (error) {
      await _problem(request, error.status, error.message);
    } on FormatException catch (error) {
      await _problem(request, 400, error.message.toString());
    } on TimeoutException {
      await _problem(request, 504, 'DAMから応答がありません');
    } on Object catch (error) {
      onLog('リモコン要求に失敗しました: $error');
      await _problem(request, 503, 'DAMに接続できません');
    } finally {
      _activeRequests--;
    }
  }

  void _verifySameOrigin(HttpRequest request) {
    final origin = request.headers.value('Origin');
    if (origin == null) return;
    final currentUrl = _url;
    if (currentUrl == null) throw const _HttpProblem(503, '準備中です');
    final uri = Uri.parse(currentUrl);
    final expected = '${uri.scheme}://${uri.authority}';
    if (origin != expected) {
      throw const _HttpProblem(403, '別のページからは操作できません');
    }
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    const maximum = 4096;
    final bytes = <int>[];
    var oversized = false;
    await for (final chunk in request) {
      if (oversized || bytes.length + chunk.length > maximum) {
        oversized = true;
        continue;
      }
      bytes.addAll(chunk);
    }
    if (oversized) {
      throw const _HttpProblem(413, '送信データが大きすぎます');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      throw const _HttpProblem(400, 'JSONを読み取れません');
    }
    if (decoded is! Map) {
      throw const _HttpProblem(400, '無効なJSONです');
    }
    return Map<String, dynamic>.from(decoded);
  }

  bool _consumeRate(String address) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - const Duration(minutes: 1).inMilliseconds;
    final times = _requestTimes.putIfAbsent(address, () => <int>[])
      ..removeWhere((value) => value < cutoff);
    if (times.length >= 180) return false;
    times.add(now);
    if (_requestTimes.length > 128) {
      _requestTimes.removeWhere(
        (_, values) => values.isEmpty || values.last < cutoff,
      );
    }
    return true;
  }

  static bool _isPrivateClient(InternetAddress? address) {
    if (address == null || address.isLoopback) return address != null;
    if (address.type != InternetAddressType.IPv4) return false;
    final parts = address.address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final first = parts[0]!;
    final second = parts[1]!;
    return first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }

  static Future<String?> _findPreferredLanAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final candidates = <({String address, int score})>[];
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      var score = 0;
      if (name.contains('wi-fi') || name.contains('wlan')) score += 30;
      if (name.contains('ethernet')) score += 20;
      if (name.contains('virtual') ||
          name.contains('vethernet') ||
          name.contains('vmware') ||
          name.contains('virtualbox') ||
          name.contains('tailscale')) {
        score -= 100;
      }
      for (final address in interface.addresses) {
        if (_isPrivateClient(address) && !address.isLoopback) {
          candidates.add((address: address.address, score: score));
        }
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort((left, right) => right.score.compareTo(left.score));
    return candidates.first.address;
  }

  static Future<void> _html(HttpResponse response, String body) async {
    _securityHeaders(response);
    response.headers.contentType = ContentType.html;
    response.write(body);
    await response.close();
  }

  static Future<void> _json(
    HttpResponse response,
    Map<String, Object> body,
  ) async {
    _securityHeaders(response);
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  static Future<void> _problem(
    HttpRequest request,
    int status,
    String message,
  ) async {
    try {
      request.response.statusCode = status;
      await _json(request.response, <String, Object>{'error': message});
    } on Object {
      // The peer may have disconnected while DAM was processing the request.
    }
  }

  static void _securityHeaders(HttpResponse response) {
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

  static String _randomHex(int byteCount) {
    final random = Random.secure();
    return List<int>.generate(
      byteCount,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}

class _HttpProblem implements Exception {
  const _HttpProblem(this.status, this.message);

  final int status;
  final String message;
}
