// Project: DAM for Windows Tools
// File: sidecar_service.dart
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
import 'app_paths.dart';

typedef SidecarEventHandler = FutureOr<void> Function(
  Map<String, dynamic> event,
);

class SidecarService {
  SidecarService({
    required this.paths,
    required this.onEvent,
    required this.onLog,
  });

  final AppPaths paths;
  final SidecarEventHandler onEvent;
  final void Function(String message) onLog;

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  bool _stopping = false;
  final Random _secureRandom = Random.secure();
  final Map<String, Completer<List<RemoteSong>>> _remoteSearches =
      <String, Completer<List<RemoteSong>>>{};
  final Map<String, Completer<RemoteSongDetail>> _remoteDetails =
      <String, Completer<RemoteSongDetail>>{};
  final Map<String, Completer<RemoteReservationResult>> _remoteReservations =
      <String, Completer<RemoteReservationResult>>{};
  final Map<String, Completer<RemoteFavoriteResult>> _remoteFavorites =
      <String, Completer<RemoteFavoriteResult>>{};
  final Map<String, Completer<Map<String, dynamic>>> _remoteCommands =
      <String, Completer<Map<String, dynamic>>>{};

  bool get isRunning => _process != null;
  static const int _maximumProtocolLineLength = 4 * 1024 * 1024;

  Future<void> start(AppSettings settings) async {
    if (_process != null) return;
    if (!await paths.sidecarEntry.exists()) {
      throw StateError('Fridaヘルパーが見つかりません: ${paths.sidecarEntry.path}');
    }
    _stopping = false;
    final process = await Process.start(
      paths.nodeExecutable,
      <String>[paths.sidecarEntry.path],
      workingDirectory: paths.sidecarEntry.parent.path,
      runInShell: paths.nodeExecutable == 'node',
      environment: <String, String>{
        ...Platform.environment,
        'NODE_NO_WARNINGS': '1',
        'DAM_TOOLS_MEDIA_ORIGIN': AppConfig.mediaServerOrigin,
      },
    );
    _process = process;
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: (Object error) {
            onLog('Fridaヘルパー標準出力エラー: $error');
          },
        );
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isNotEmpty) onLog('Fridaヘルパー: $line');
        });
    unawaited(
      process.exitCode.then((exitCode) async {
        if (identical(_process, process)) _process = null;
        if (!_stopping) {
          _failRemoteRequests(StateError('Fridaヘルパーが終了しました'));
          onLog('Fridaヘルパーが終了しました (exit $exitCode)');
          await onEvent(<String, dynamic>{
            'type': 'status',
            'state': 'helper-exited',
            'detail': 'exit $exitCode',
          });
        }
      }),
    );
    send(<String, dynamic>{'type': 'config', ...settings.toJson()});
  }

  Future<void> updateConfig(AppSettings settings) async {
    send(<String, dynamic>{'type': 'config', ...settings.toJson()});
  }

  void respondToPreparation({
    required String requestId,
    required bool accepted,
    String? localUrl,
    String? error,
  }) {
    send(<String, dynamic>{
      'type': 'prepareResult',
      'requestId': requestId,
      'accepted': accepted,
      'localUrl': ?localUrl,
      'error': ?error,
    });
  }

  void reconnect() => send(const <String, dynamic>{'type': 'reconnect'});

  Future<List<RemoteSong>> searchSongs(
    String query, {
    RemoteSearchMode mode = RemoteSearchMode.keyword,
  }) async {
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
    if (!isRunning) throw StateError('DAM接続ヘルパーが起動していません');
    final requestId = _randomId();
    final completer = Completer<List<RemoteSong>>();
    _remoteSearches[requestId] = completer;
    send(<String, dynamic>{
      'type': 'remoteSearch',
      'requestId': requestId,
      'query': cleaned,
      'mode': mode.wireName,
    });
    try {
      return await completer.future.timeout(const Duration(seconds: 17));
    } finally {
      _remoteSearches.remove(requestId);
    }
  }

  Future<RemoteReservationResult> reserveSong(
    String token, {
    RemoteReservationOptions options = const RemoteReservationOptions(),
  }) async {
    if (token.isEmpty ||
        token.length > 160 ||
        !RegExp(r'^[0-9A-Za-z_-]+$').hasMatch(token)) {
      throw const FormatException('無効な検索結果です。もう一度検索してください');
    }
    if (!isRunning) throw StateError('DAM接続ヘルパーが起動していません');
    final requestId = _randomId();
    final completer = Completer<RemoteReservationResult>();
    _remoteReservations[requestId] = completer;
    send(<String, dynamic>{
      'type': 'remoteReserve',
      'requestId': requestId,
      'token': token,
      'mode': options.mode.name,
      'key': options.key.clamp(-7, 7),
      'scoring': options.scoring,
      'playType': options.playType.name,
    });
    try {
      return await completer.future.timeout(const Duration(seconds: 22));
    } finally {
      _remoteReservations.remove(requestId);
    }
  }

  Future<RemoteSongDetail> songDetail(String token) async {
    if (token.isEmpty ||
        token.length > 160 ||
        !RegExp(r'^[0-9A-Za-z_-]+$').hasMatch(token)) {
      throw const FormatException('無効な検索結果です。もう一度検索してください');
    }
    if (!isRunning) throw StateError('DAM接続ヘルパーが起動していません');
    final requestId = _randomId();
    final completer = Completer<RemoteSongDetail>();
    _remoteDetails[requestId] = completer;
    send(<String, dynamic>{
      'type': 'remoteDetail',
      'requestId': requestId,
      'token': token,
    });
    try {
      return await completer.future.timeout(const Duration(seconds: 22));
    } finally {
      _remoteDetails.remove(requestId);
    }
  }

  Future<RemoteFavoriteResult> updateFavorite(
    String token, {
    required bool favorite,
  }) async {
    if (token.isEmpty ||
        token.length > 160 ||
        !RegExp(r'^[0-9A-Za-z_-]+$').hasMatch(token)) {
      throw const FormatException('無効な検索結果です。もう一度検索してください');
    }
    if (!isRunning) throw StateError('DAM接続ヘルパーが起動していません');
    final requestId = _randomId();
    final completer = Completer<RemoteFavoriteResult>();
    _remoteFavorites[requestId] = completer;
    send(<String, dynamic>{
      'type': 'remoteFavorite',
      'requestId': requestId,
      'token': token,
      'action': favorite ? 'add' : 'remove',
    });
    try {
      return await completer.future.timeout(const Duration(seconds: 22));
    } finally {
      _remoteFavorites.remove(requestId);
    }
  }

  Future<RemoteControlState> remoteState() async {
    final result = await _remoteCommand('remoteState');
    return RemoteControlState.fromJson(result);
  }

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
    final result = await _remoteCommand('remoteControl', <String, Object>{
      'action': action,
    });
    return RemoteControlState.fromJson(result);
  }

  Future<List<RemoteQueueEntry>> remoteQueue() async {
    final result = await _remoteCommand('remoteQueue');
    return _queueFromResult(result);
  }

  Future<List<RemoteQueueEntry>> remoteQueueAction(
    String action,
    String token,
  ) async {
    const allowed = <String>{'remove', 'moveUp', 'moveDown'};
    if (!allowed.contains(action) ||
        !RegExp(r'^q_[cn]_[0-9]+$').hasMatch(token)) {
      throw const FormatException('無効な予約操作です');
    }
    final result = await _remoteCommand('remoteQueueAction', <String, Object>{
      'action': action,
      'token': token,
    });
    return _queueFromResult(result);
  }

  Future<Map<String, dynamic>> _remoteCommand(
    String type, [
    Map<String, Object> fields = const <String, Object>{},
  ]) async {
    if (!isRunning) throw StateError('DAM接続ヘルパーが起動していません');
    final requestId = _randomId();
    final completer = Completer<Map<String, dynamic>>();
    _remoteCommands[requestId] = completer;
    send(<String, dynamic>{'type': type, 'requestId': requestId, ...fields});
    try {
      return await completer.future.timeout(const Duration(seconds: 6));
    } finally {
      _remoteCommands.remove(requestId);
    }
  }

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

  void send(Map<String, dynamic> command) {
    final process = _process;
    if (process == null) return;
    try {
      process.stdin.writeln(jsonEncode(command));
    } on Object catch (error) {
      onLog('Fridaヘルパーへの送信に失敗しました: $error');
    }
  }

  Future<void> stop() async {
    _failRemoteRequests(StateError('アプリを終了しています'));
    final process = _process;
    if (process == null) return;
    _stopping = true;
    send(const <String, dynamic>{'type': 'shutdown'});
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill();
    }
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    await process.stdin.close();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _process = null;
  }

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    if (line.length > _maximumProtocolLineLength) {
      onLog('Fridaヘルパーからの巨大なJSON Linesメッセージを拒否しました');
      return;
    }
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) {
        if (_handleRemoteResult(decoded)) return;
        final result = onEvent(decoded);
        if (result is Future<void>) {
          unawaited(
            result.catchError((Object error) {
              onLog('Fridaイベント処理に失敗しました: $error');
            }),
          );
        }
        return;
      }
    } on FormatException {
      // Preserve non-protocol output as a diagnostic line.
    }
    onLog('Fridaヘルパー: $line');
  }

  bool _handleRemoteResult(Map<String, dynamic> event) {
    final type = event['type']?.toString();
    final requestId = event['requestId']?.toString() ?? '';
    if (type == 'remote-search-result') {
      final completer = _remoteSearches.remove(requestId);
      if (completer == null || completer.isCompleted) return true;
      final error = event['error']?.toString().trim() ?? '';
      if (error.isNotEmpty) {
        completer.completeError(StateError(error));
        return true;
      }
      final rawRows = event['rows'];
      final rows = <RemoteSong>[];
      final maximumRows = event['mode'] == 'favorites' ? 100 : 50;
      if (rawRows is List) {
        for (final raw in rawRows) {
          if (raw is! Map) continue;
          final song = RemoteSong.fromJson(Map<String, dynamic>.from(raw));
          if (song.isDisplayableSearchResult) rows.add(song);
          if (rows.length >= maximumRows) break;
        }
      }
      completer.complete(List<RemoteSong>.unmodifiable(rows));
      return true;
    }
    if (type == 'remote-reserve-result') {
      final completer = _remoteReservations.remove(requestId);
      if (completer == null || completer.isCompleted) return true;
      final error = event['error']?.toString().trim() ?? '';
      if (error.isNotEmpty) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(RemoteReservationResult.fromJson(event));
      }
      return true;
    }
    if (type == 'remote-detail-result') {
      final completer = _remoteDetails.remove(requestId);
      if (completer == null || completer.isCompleted) return true;
      final error = event['error']?.toString().trim() ?? '';
      if (error.isNotEmpty) {
        completer.completeError(StateError(error));
        return true;
      }
      final rawDetail = event['detail'];
      if (rawDetail is! Map) {
        completer.completeError(StateError('DAMから不正な曲詳細を受信しました'));
      } else {
        completer.complete(
          RemoteSongDetail.fromJson(Map<String, dynamic>.from(rawDetail)),
        );
      }
      return true;
    }
    if (type == 'remote-favorite-result') {
      final completer = _remoteFavorites.remove(requestId);
      if (completer == null || completer.isCompleted) return true;
      final error = event['error']?.toString().trim() ?? '';
      if (error.isNotEmpty) {
        completer.completeError(StateError(error));
      } else {
        completer.complete(RemoteFavoriteResult.fromJson(event));
      }
      return true;
    }
    if (type == 'remote-state-result' ||
        type == 'remote-control-result' ||
        type == 'remote-queue-result' ||
        type == 'remote-queue-action-result') {
      final completer = _remoteCommands.remove(requestId);
      if (completer == null || completer.isCompleted) return true;
      final error = event['error']?.toString().trim() ?? '';
      if (error.isNotEmpty) {
        completer.completeError(StateError(error));
        return true;
      }
      final rawResult = event['result'];
      if (rawResult is List) {
        completer.complete(<String, dynamic>{'rows': rawResult});
      } else if (rawResult is Map) {
        completer.complete(Map<String, dynamic>.from(rawResult));
      } else {
        completer.completeError(StateError('DAMから不正な応答を受信しました'));
      }
      return true;
    }
    return false;
  }

  void _failRemoteRequests(Object error) {
    for (final completer in _remoteSearches.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    for (final completer in _remoteDetails.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    for (final completer in _remoteReservations.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    for (final completer in _remoteFavorites.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    for (final completer in _remoteCommands.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _remoteSearches.clear();
    _remoteDetails.clear();
    _remoteReservations.clear();
    _remoteFavorites.clear();
    _remoteCommands.clear();
  }

  String _randomId() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}
