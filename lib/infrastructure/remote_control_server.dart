// Project: DAM for Windows Tools
// File: remote_control_server.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../config/app_config.dart';
import 'remote/remote_access_policy.dart';
import 'remote/remote_api_router.dart';
import 'remote/remote_handlers.dart';
import 'remote/remote_http.dart';
import 'remote_page_provider.dart';

export 'remote/remote_handlers.dart';

class RemoteControlServer {
  RemoteControlServer({
    required RemoteSongSearch search,
    required RemoteSongDetailReader readSongDetail,
    required RemoteSongReservation reserve,
    required RemoteFavoriteCommand favorite,
    required RemoteStateReader readState,
    required RemotePlaybackCommand controlPlayback,
    required RemoteQueueReader readQueue,
    required RemoteQueueCommand controlQueue,
    required RemoteHistoryReader readHistory,
    required this.onLog,
    this.port = AppConfig.remoteServerPort,
    InternetAddress? bindAddress,
    this.advertisedAddress,
    String? sessionToken,
    RemotePageProvider? pageProvider,
  }) : _bindAddress = bindAddress ?? InternetAddress.anyIPv4,
       _sessionToken = sessionToken ?? _randomHex(32),
       _pageProvider = pageProvider ?? RemotePageProvider(),
       _api = RemoteApiRouter(
         RemoteHandlers(
           search: search,
           readSongDetail: readSongDetail,
           reserve: reserve,
           favorite: favorite,
           readState: readState,
           controlPlayback: controlPlayback,
           readQueue: readQueue,
           controlQueue: controlQueue,
           readHistory: readHistory,
         ),
       );

  static const int maximumConcurrentRequests = 8;

  final void Function(String message) onLog;
  final int port;
  final InternetAddress _bindAddress;
  final String? advertisedAddress;
  final String _sessionToken;
  final RemotePageProvider _pageProvider;
  final RemoteApiRouter _api;
  final RemoteAccessPolicy _access = RemoteAccessPolicy();

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
        await RemoteAccessPolicy.findPreferredLanAddress() ??
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
    _access.clear();
    if (server != null) await server.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    if (_activeRequests >= maximumConcurrentRequests) {
      await RemoteHttp.problem(request, 503, '処理が混み合っています');
      return;
    }
    _activeRequests++;
    try {
      final remoteAddress = request.connectionInfo?.remoteAddress;
      if (!RemoteAccessPolicy.isPrivateClient(remoteAddress)) {
        await RemoteHttp.problem(request, 403, 'この端末からは接続できません');
        return;
      }
      if (!_access.isRateAllowed(remoteAddress?.address ?? '?')) {
        await RemoteHttp.problem(request, 429, '操作が多すぎます。少し待ってください');
        return;
      }
      await _route(request);
    } on RemoteHttpProblem catch (error) {
      await RemoteHttp.problem(request, error.status, error.message);
    } on FormatException catch (error) {
      await RemoteHttp.problem(request, 400, error.message.toString());
    } on TimeoutException {
      await RemoteHttp.problem(request, 504, 'DAMから応答がありません');
    } on Object catch (error) {
      onLog('リモコン要求に失敗しました: $error');
      await RemoteHttp.problem(request, 503, 'DAMに接続できません');
    } finally {
      _activeRequests--;
    }
  }

  Future<void> _route(HttpRequest request) async {
    final pagePath = '/$_sessionToken/';
    final path = request.uri.path;
    if (request.method == 'GET' && path == pagePath) {
      await RemoteHttp.html(request.response, await _pageProvider.load());
      return;
    }
    final apiPrefix = '${pagePath}api/';
    final endpoint = path.startsWith(apiPrefix)
        ? path.substring(apiPrefix.length)
        : '';
    if (request.method != 'POST' ||
        !RemoteApiRouter.endpoints.contains(endpoint)) {
      throw const RemoteHttpProblem(404, '見つかりません');
    }
    RemoteHttp.verifySameOrigin(request, _url);
    if (request.headers.contentType?.mimeType != 'application/json') {
      throw const RemoteHttpProblem(415, 'JSON形式で送信してください');
    }
    await _api.handle(
      endpoint,
      await RemoteHttp.readJson(request),
      request.response,
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
