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

/// Sidecarから届いた非同期イベントをアプリケーション層へ渡す関数型です。
typedef SidecarEventHandler = FutureOr<void> Function(
  Map<String, dynamic> event,
);

/// 同梱Node/FridaヘルパーとのJSON Lines通信を、用途別APIとして公開します。
///
/// プロセス管理と相関ID管理を内部へ隠し、呼び出し側は検索・予約・URL準備を
/// 通常の非同期メソッドとして扱えます。
class SidecarService {
  /// 実行パス、イベント通知先、診断ログを配線してサービスを生成します。
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
        // Node側が配布版と開発版の描画DLL・アイコンを同じ基準で解決します。
        'DAM_TOOLS_APP_ROOT': paths.applicationDirectory.path,
        // DAMに旧DLLが残る更新直後も、新しい版固有DLLを確実に選べるようにします。
        'DAM_TOOLS_APP_VERSION': AppConfig.productVersion,
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

  /// Nodeヘルパープロセスが起動中か返します。
  bool get isRunning => _process.isRunning;

  /// Sidecarファイルを確認してプロセスを起動し、現在設定を最初に送信します。
  Future<void> start(AppSettings settings) async {
    if (isRunning) return;
    if (!await paths.sidecarEntry.exists()) {
      throw StateError('Fridaヘルパーが見つかりません: ${paths.sidecarEntry.path}');
    }
    await _process.start();
    await updateConfig(settings);
  }

  /// GUIで確定した設定をSidecarの実行時構成へ反映します。
  Future<void> updateConfig(AppSettings settings) async {
    send(<String, dynamic>{'type': 'config', ...settings.toJson()});
  }

  /// Frida側で最大2秒待機しているURL置換要求へ、ローカル登録結果を返します。
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

  /// Sidecarへ現在のDAM接続を破棄して再探索するよう要求します。
  void reconnect() => send(const <String, dynamic>{'type': 'reconnect'});

  /// 指定モードで曲を検索し、検証済み結果だけを返します。
  Future<List<RemoteSong>> searchSongs(
    String query, {
    RemoteSearchMode mode = RemoteSearchMode.keyword,
  }) => _remote.searchSongs(query, mode: mode);

  /// 検索結果トークンと予約条件を使ってDAMへ予約します。
  Future<RemoteReservationResult> reserveSong(
    String token, {
    RemoteReservationOptions options = const RemoteReservationOptions(),
  }) => _remote.reserveSong(token, options: options);

  /// 検索結果トークンに完全一致する曲詳細を取得します。
  Future<RemoteSongDetail> songDetail(String token) =>
      _remote.songDetail(token);

  /// 指定曲のお気に入り状態をDAM側で更新します。
  Future<RemoteFavoriteResult> updateFavorite(
    String token, {
    required bool favorite,
  }) => _remote.updateFavorite(token, favorite: favorite);

  /// DAMの接続・演奏・キー・採点状態を取得します。
  Future<RemoteControlState> remoteState() => _remote.remoteState();

  /// 許可済みの演奏操作をDAMへ送信し、更新後の状態を返します。
  Future<RemoteControlState> remoteControl(String action) =>
      _remote.remoteControl(action);

  /// DAMが現在保持する予約一覧を取得します。
  Future<List<RemoteQueueEntry>> remoteQueue() => _remote.remoteQueue();

  /// 予約の取消または順序変更を行い、更新後の一覧を返します。
  Future<List<RemoteQueueEntry>> remoteQueueAction(
    String action,
    String token,
  ) => _remote.remoteQueueAction(action, token);

  /// 低水準のJSONコマンドをNodeヘルパーへ1行で送信します。
  void send(Map<String, dynamic> command) => _process.send(command);

  /// 待機中要求をすべて失敗させてから、Nodeヘルパーを終了します。
  Future<void> stop() async {
    _remote.failAll(StateError('アプリを終了しています'));
    await _process.stop();
  }

  /// 応答イベントを相関ID待機へ先に渡し、残りを通常イベントとして通知します。
  Future<void> _handleMessage(Map<String, dynamic> event) async {
    if (_remote.handleEvent(event)) return;
    await onEvent(event);
  }

  /// 予期しないヘルパー終了で待機中要求を解放し、GUI状態を切断へ更新します。
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
