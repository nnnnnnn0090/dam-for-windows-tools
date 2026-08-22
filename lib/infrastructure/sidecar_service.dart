// Project: DAM for Windows Tools
// File: sidecar_service.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:async';
import 'dart:io';

import '../config/app_config.dart';
import '../domain/app_settings.dart';
import '../domain/remote.dart';
import 'app_paths.dart';
import 'sidecar/json_line_process.dart';
import 'sidecar/remote_request_broker.dart';

typedef SidecarEventHandler = FutureOr<void> Function(
  Map<String, dynamic> event,
);

class SidecarService {
  SidecarService({
    required this.paths,
    required this.onEvent,
    required this.onLog,
  }) {
    _process = JsonLineProcess(
      executable: paths.nodeExecutable,
      entryPoint: paths.sidecarEntry.path,
      workingDirectory: paths.sidecarEntry.parent.path,
      environment: <String, String>{
        ...Platform.environment,
        'NODE_NO_WARNINGS': '1',
        'DAM_TOOLS_MEDIA_ORIGIN': AppConfig.mediaServerOrigin,
      },
      onMessage: _handleMessage,
      onExit: _handleExit,
      onLog: onLog,
    );
    _remote = RemoteRequestBroker(send: send, isRunning: () => isRunning);
  }

  final AppPaths paths;
  final SidecarEventHandler onEvent;
  final void Function(String message) onLog;

  late final JsonLineProcess _process;
  late final RemoteRequestBroker _remote;

  bool get isRunning => _process.isRunning;

  Future<void> start(AppSettings settings) async {
    if (isRunning) return;
    if (!await paths.sidecarEntry.exists()) {
      throw StateError('Fridaヘルパーが見つかりません: ${paths.sidecarEntry.path}');
    }
    await _process.start();
    await updateConfig(settings);
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
  }) => _remote.searchSongs(query, mode: mode);

  Future<RemoteReservationResult> reserveSong(
    String token, {
    RemoteReservationOptions options = const RemoteReservationOptions(),
  }) => _remote.reserveSong(token, options: options);

  Future<RemoteSongDetail> songDetail(String token) =>
      _remote.songDetail(token);

  Future<RemoteFavoriteResult> updateFavorite(
    String token, {
    required bool favorite,
  }) => _remote.updateFavorite(token, favorite: favorite);

  Future<RemoteControlState> remoteState() => _remote.remoteState();

  Future<RemoteControlState> remoteControl(String action) =>
      _remote.remoteControl(action);

  Future<List<RemoteQueueEntry>> remoteQueue() => _remote.remoteQueue();

  Future<List<RemoteQueueEntry>> remoteQueueAction(
    String action,
    String token,
  ) => _remote.remoteQueueAction(action, token);

  void send(Map<String, dynamic> command) => _process.send(command);

  Future<void> stop() async {
    _remote.failAll(StateError('アプリを終了しています'));
    await _process.stop();
  }

  Future<void> _handleMessage(Map<String, dynamic> event) async {
    if (_remote.handleEvent(event)) return;
    await onEvent(event);
  }

  Future<void> _handleExit(int exitCode) async {
    _remote.failAll(StateError('Fridaヘルパーが終了しました'));
    onLog('Fridaヘルパーが終了しました (exit $exitCode)');
    await onEvent(<String, dynamic>{
      'type': 'status',
      'state': 'helper-exited',
      'detail': 'exit $exitCode',
    });
  }
}
