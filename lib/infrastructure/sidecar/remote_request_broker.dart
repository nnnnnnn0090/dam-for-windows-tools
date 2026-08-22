// Project: DAM for Windows Tools
// File: sidecar/remote_request_broker.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:async';
import 'dart:math';

import '../../domain/remote.dart';

/// 検証済みSidecarコマンドを送信する関数型です。
typedef SidecarCommandSender = void Function(Map<String, dynamic> command);

/// Webリモコン要求とSidecar応答を、推測困難な相関IDで対応付けます。
///
/// 各操作の入力許可リスト・件数上限・タイムアウトをここで統一し、ブラウザから
/// 任意のFridaコマンドを送れないようにします。
class RemoteRequestBroker {
  /// コマンド送信先とヘルパー稼働確認関数を受け取ります。
  RemoteRequestBroker({required this.send, required this.isRunning});

  static final RegExp _tokenPattern = RegExp(r'^[0-9A-Za-z_-]+$');
  static const Set<String> _resultTypes = <String>{
    'remote-search-result',
    'remote-reserve-result',
    'remote-detail-result',
    'remote-favorite-result',
    'remote-state-result',
    'remote-control-result',
    'remote-queue-result',
    'remote-queue-action-result',
  };

  final SidecarCommandSender send;
  final bool Function() isRunning;
  final Random _secureRandom = Random.secure();
  final Map<String, _PendingRequest<dynamic>> _pending =
      <String, _PendingRequest<dynamic>>{};

  /// 検索語とモードを検証し、最大件数までの曲・歌手結果を取得します。
  Future<List<RemoteSong>> searchSongs(
    String query, {
    RemoteSearchMode mode = RemoteSearchMode.keyword,
  }) {
    final cleaned = query
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final needsQuery =
        mode == RemoteSearchMode.keyword ||
        mode == RemoteSearchMode.title ||
        mode == RemoteSearchMode.artist;
    if ((needsQuery && cleaned.isEmpty) || cleaned.length > 80) {
      throw const FormatException('検索語は1～80文字で入力してください');
    }
    return _request<List<RemoteSong>>(
      type: 'remoteSearch',
      fields: <String, Object>{'query': cleaned, 'mode': mode.wireName},
      timeout: const Duration(seconds: 17),
      decode: _decodeSongs,
    );
  }

  /// 操作トークンを検証し、キー・採点・演奏タイプを含む予約を実行します。
  Future<RemoteReservationResult> reserveSong(
    String token, {
    RemoteReservationOptions options = const RemoteReservationOptions(),
  }) {
    _validateToken(token);
    return _request<RemoteReservationResult>(
      type: 'remoteReserve',
      fields: <String, Object>{
        'token': token,
        'mode': options.mode.name,
        'key': options.key.clamp(-7, 7),
        'scoring': options.scoring,
        'playType': options.playType.name,
      },
      timeout: const Duration(seconds: 22),
      decode: RemoteReservationResult.fromJson,
    );
  }

  /// 検索結果トークンから歌いだし・原曲キー・対応素材を取得します。
  Future<RemoteSongDetail> songDetail(String token) {
    _validateToken(token);
    return _request<RemoteSongDetail>(
      type: 'remoteDetail',
      fields: <String, Object>{'token': token},
      timeout: const Duration(seconds: 22),
      decode: (event) {
        final rawDetail = event['detail'];
        if (rawDetail is! Map) {
          throw StateError('DAMから不正な曲詳細を受信しました');
        }
        return RemoteSongDetail.fromJson(Map<String, dynamic>.from(rawDetail));
      },
    );
  }

  /// 検索結果トークンに対するお気に入り登録または解除を実行します。
  Future<RemoteFavoriteResult> updateFavorite(
    String token, {
    required bool favorite,
  }) {
    _validateToken(token);
    return _request<RemoteFavoriteResult>(
      type: 'remoteFavorite',
      fields: <String, Object>{
        'token': token,
        'action': favorite ? 'add' : 'remove',
      },
      timeout: const Duration(seconds: 22),
      decode: RemoteFavoriteResult.fromJson,
    );
  }

  /// DAMの現在状態を短いタイムアウトで取得します。
  Future<RemoteControlState> remoteState() async {
    return RemoteControlState.fromJson(await _command('remoteState'));
  }

  /// 許可リストにある演奏操作だけをDAMへ送り、更新後状態を返します。
  Future<RemoteControlState> remoteControl(String action) async {
    const allowed = <String>{
      'pause',
      'resume',
      'stop',
      'restart',
      'keyDown',
      'keyUp',
      'keyReset',
      'scoringOn',
      'scoringOff',
    };
    if (!allowed.contains(action)) {
      throw const FormatException('無効な再生操作です');
    }
    return RemoteControlState.fromJson(
      await _command('remoteControl', <String, Object>{'action': action}),
    );
  }

  /// DAMの通常予約と割り込み予約をまとめた一覧を取得します。
  Future<List<RemoteQueueEntry>> remoteQueue() async {
    return _queueFromResult(await _command('remoteQueue'));
  }

  /// 形式検証済みの予約トークンに対して、取消または順序変更を実行します。
  Future<List<RemoteQueueEntry>> remoteQueueAction(
    String action,
    String token,
  ) async {
    const allowed = <String>{'remove', 'moveUp', 'moveDown'};
    if (!allowed.contains(action) ||
        !RegExp(r'^q_[cn]_[0-9]+$').hasMatch(token)) {
      throw const FormatException('無効な予約操作です');
    }
    return _queueFromResult(
      await _command('remoteQueueAction', <String, Object>{
        'action': action,
        'token': token,
      }),
    );
  }

  /// Sidecar応答を待機中要求へ配り、エラー応答も必ずCompleterを解放します。
  bool handleEvent(Map<String, dynamic> event) {
    final type = event['type']?.toString();
    if (!_resultTypes.contains(type)) return false;
    final requestId = event['requestId']?.toString() ?? '';
    final pending = _pending.remove(requestId);
    if (pending == null || pending.isCompleted) return true;
    final error = event['error']?.toString().trim() ?? '';
    if (error.isNotEmpty) {
      pending.completeError(StateError(error));
    } else {
      pending.complete(event);
    }
    return true;
  }

  /// プロセス終了時などに、すべての待機中要求を同じ理由で失敗させます。
  void failAll(Object error) {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
  }

  /// 単一結果または一覧結果を共通形式へ変換する短時間コマンドを送ります。
  Future<Map<String, dynamic>> _command(
    String type, [
    Map<String, Object> fields = const <String, Object>{},
  ]) {
    return _request<Map<String, dynamic>>(
      type: type,
      fields: fields,
      timeout: const Duration(seconds: 6),
      decode: (event) {
        final rawResult = event['result'];
        if (rawResult is List) return <String, dynamic>{'rows': rawResult};
        if (rawResult is Map) return Map<String, dynamic>.from(rawResult);
        throw StateError('DAMから不正な応答を受信しました');
      },
    );
  }

  /// 相関IDを発行して要求を送信し、応答・タイムアウト後に待機表から除去します。
  Future<T> _request<T>({
    required String type,
    required Map<String, Object> fields,
    required Duration timeout,
    required T Function(Map<String, dynamic> event) decode,
  }) async {
    if (!isRunning()) throw StateError('DAM接続ヘルパーが起動していません');
    final requestId = _randomId();
    final pending = _PendingRequest<T>(decode);
    _pending[requestId] = pending;
    send(<String, dynamic>{'type': type, 'requestId': requestId, ...fields});
    try {
      return await pending.future.timeout(timeout);
    } finally {
      _pending.remove(requestId);
    }
  }

  /// 検索結果をドメイン型へ変換し、無効行と上限超過行を除外します。
  static List<RemoteSong> _decodeSongs(Map<String, dynamic> event) {
    final rows = <RemoteSong>[];
    final maximumRows = event['mode'] == 'favorites' ? 100 : 50;
    final rawRows = event['rows'];
    if (rawRows is List) {
      for (final raw in rawRows) {
        if (raw is! Map) continue;
        final song = RemoteSong.fromJson(Map<String, dynamic>.from(raw));
        if (song.isDisplayableSearchResult) rows.add(song);
        if (rows.length >= maximumRows) break;
      }
    }
    return List<RemoteSong>.unmodifiable(rows);
  }

  /// 予約一覧を検証し、DAMの最大表示件数までに制限します。
  static List<RemoteQueueEntry> _queueFromResult(Map<String, dynamic> result) {
    final rawRows = result['rows'];
    if (rawRows is! List) return const <RemoteQueueEntry>[];
    final rows = <RemoteQueueEntry>[];
    for (final raw in rawRows) {
      if (raw is! Map) continue;
      final row = RemoteQueueEntry.fromJson(Map<String, dynamic>.from(raw));
      if (row.token.isNotEmpty && row.queueId > 0) rows.add(row);
      if (rows.length >= 11) break;
    }
    return List<RemoteQueueEntry>.unmodifiable(rows);
  }

  /// 検索結果トークンを、長さと許可文字の両方で検証します。
  static void _validateToken(String token) {
    if (token.isEmpty || token.length > 160 || !_tokenPattern.hasMatch(token)) {
      throw const FormatException('無効な検索結果です。もう一度検索してください');
    }
  }

  /// 要求の衝突と推測を防ぐ128bit相関IDを生成します。
  String _randomId() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// 1件のSidecar要求について、応答の型変換と完了状態を保持します。
class _PendingRequest<T> {
  /// 応答イベント専用のデコーダーを持つ未完了要求を生成します。
  _PendingRequest(this.decode);

  final T Function(Map<String, dynamic> event) decode;
  final Completer<T> _completer = Completer<T>();

  /// 呼び出し側が応答を待機するFutureを返します。
  Future<T> get future => _completer.future;

  /// 成功または失敗で既に完了したか返します。
  bool get isCompleted => _completer.isCompleted;

  /// 応答を型変換して完了し、変換例外はスタック付きエラーとして返します。
  void complete(Map<String, dynamic> event) {
    try {
      _completer.complete(decode(event));
    } on Object catch (error, stackTrace) {
      _completer.completeError(error, stackTrace);
    }
  }

  /// プロセス終了や応答エラーで待機中要求を失敗として完了します。
  void completeError(Object error) => _completer.completeError(error);
}
