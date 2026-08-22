// Project: DAM for Windows Tools
// File: remote/remote_api_router.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:io';

import '../../domain/remote.dart';
import 'remote_handlers.dart';
import 'remote_http.dart';

/// Web APIの入力をドメイン型へ変換し、許可済みハンドラーだけを呼び出します。
class RemoteApiRouter {
  /// アプリ実行サービスへ接続済みの操作ハンドラーを受け取ります。
  const RemoteApiRouter(this.handlers);

  static const Set<String> endpoints = <String>{
    'search',
    'detail',
    'reserve',
    'favorite',
    'state',
    'control',
    'queue',
    'queue-action',
    'history',
  };

  final RemoteHandlers handlers;

  /// 許可済みエンドポイント名を対応処理へ振り分けます。
  Future<void> handle(
    String endpoint,
    Map<String, dynamic> body,
    HttpResponse response,
  ) async {
    switch (endpoint) {
      case 'search':
        await _search(body, response);
      case 'detail':
        await _detail(body, response);
      case 'reserve':
        await _reserve(body, response);
      case 'favorite':
        await _favorite(body, response);
      case 'state':
        await RemoteHttp.json(response, (await handlers.readState()).toJson());
      case 'control':
        await _control(body, response);
      case 'queue':
        await _queue(response);
      case 'queue-action':
        await _queueAction(body, response);
      case 'history':
        await _history(response);
      default:
        throw const RemoteHttpProblem(404, '見つかりません');
    }
  }

  /// 検索語と検索種別を検証し、曲・歌手結果をJSONで返します。
  Future<void> _search(Map<String, dynamic> body, HttpResponse response) async {
    final query = body['query'];
    if (query is! String) {
      throw const RemoteHttpProblem(400, '検索語を入力してください');
    }
    final mode = switch (body['mode']?.toString() ?? 'keyword') {
      'keyword' => RemoteSearchMode.keyword,
      'title' => RemoteSearchMode.title,
      'artist' => RemoteSearchMode.artist,
      'ranking' => RemoteSearchMode.ranking,
      'new' => RemoteSearchMode.newReleases,
      'favorites' => RemoteSearchMode.favorites,
      _ => throw const RemoteHttpProblem(400, '無効な検索種別です'),
    };
    final songs = await handlers.search(query, mode);
    await RemoteHttp.json(response, <String, Object>{
      'songs': songs.map((song) => song.toJson()).toList(growable: false),
    });
  }

  /// 検索結果トークンから曲詳細を取得してJSONで返します。
  Future<void> _detail(Map<String, dynamic> body, HttpResponse response) async {
    final token = body['token'];
    if (token is! String) {
      throw const RemoteHttpProblem(400, '無効な検索結果です');
    }
    await RemoteHttp.json(response, <String, Object>{
      'detail': (await handlers.readSongDetail(token)).toJson(),
    });
  }

  /// 予約方法、キー、採点、演奏タイプを検証してDAMへ予約します。
  Future<void> _reserve(
    Map<String, dynamic> body,
    HttpResponse response,
  ) async {
    final token = body['token'];
    if (token is! String) {
      throw const RemoteHttpProblem(400, '無効な検索結果です');
    }
    final modeName = body['mode'];
    if (modeName != null &&
        modeName != 'normal' &&
        modeName != 'cutIn' &&
        modeName != 'originalKey') {
      throw const RemoteHttpProblem(400, '無効な予約方法です');
    }
    final key = body['key'];
    if (key is! num || key.toInt() < -7 || key.toInt() > 7) {
      throw const RemoteHttpProblem(400, 'キーは-7～+7で指定してください');
    }
    final playType = switch (body['playType']?.toString() ?? 'standard') {
      'standard' => RemotePlayType.standard,
      'guideVocal' => RemotePlayType.guideVocal,
      'artistVideo' => RemotePlayType.artistVideo,
      _ => throw const RemoteHttpProblem(400, '無効な演奏タイプです'),
    };
    final reservationMode = switch (modeName) {
      'cutIn' => RemoteReservationMode.cutIn,
      'originalKey' => RemoteReservationMode.originalKey,
      _ => RemoteReservationMode.normal,
    };
    final result = await handlers.reserve(
      token,
      RemoteReservationOptions(
        mode: reservationMode,
        key: key.toInt(),
        scoring: body['scoring'] == true,
        playType: playType,
      ),
    );
    await RemoteHttp.json(response, <String, Object>{
      'accepted': result.accepted,
      'message': result.message,
      'videoId': result.videoId,
      'artist': result.artist,
      'title': result.title,
    });
  }

  /// お気に入りの登録または解除を実行し、確定状態を返します。
  Future<void> _favorite(
    Map<String, dynamic> body,
    HttpResponse response,
  ) async {
    final token = body['token'];
    final enabled = body['favorite'];
    if (token is! String || enabled is! bool) {
      throw const RemoteHttpProblem(400, '無効なお気に入り操作です');
    }
    final result = await handlers.favorite(token, enabled);
    await RemoteHttp.json(response, <String, Object>{
      'accepted': result.accepted,
      'favorite': result.favorite,
      'message': result.message,
    });
  }

  /// 許可リストで再検証される演奏操作をSidecarへ渡します。
  Future<void> _control(
    Map<String, dynamic> body,
    HttpResponse response,
  ) async {
    final action = body['action'];
    if (action is! String) {
      throw const RemoteHttpProblem(400, '無効な再生操作です');
    }
    await RemoteHttp.json(
      response,
      (await handlers.controlPlayback(action)).toJson(),
    );
  }

  /// 現在の予約一覧をブラウザ表示用JSONへ変換します。
  Future<void> _queue(HttpResponse response) async {
    final rows = await handlers.readQueue();
    await RemoteHttp.json(response, <String, Object>{
      'rows': rows.map((row) => row.toJson()).toList(growable: false),
    });
  }

  /// 予約操作名と行トークンを検証して、更新後の一覧を返します。
  Future<void> _queueAction(
    Map<String, dynamic> body,
    HttpResponse response,
  ) async {
    final action = body['action'];
    final token = body['token'];
    if (action is! String || token is! String) {
      throw const RemoteHttpProblem(400, '無効な予約操作です');
    }
    final rows = await handlers.controlQueue(action, token);
    await RemoteHttp.json(response, <String, Object>{
      'rows': rows.map((row) => row.toJson()).toList(growable: false),
    });
  }

  /// DAM本体が返す再生履歴を取得し、予約可能な曲一覧として返します。
  Future<void> _history(HttpResponse response) async {
    final rows = await handlers.readHistory();
    await RemoteHttp.json(response, <String, Object>{
      'rows': rows.map((row) => row.toJson()).toList(growable: false),
    });
  }
}
