// Project: DAM for Windows Tools
// File: app_runtime.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import '../domain/app_settings.dart';
import '../domain/playback.dart';
import '../domain/remote.dart';
import '../domain/tracks.dart';
import '../infrastructure/app_paths.dart';
import '../infrastructure/desktop_integration.dart';
import '../infrastructure/history_repository.dart';
import '../infrastructure/manual_video_store.dart';
import '../infrastructure/media_server.dart';
import '../infrastructure/remote_control_server.dart';
import '../infrastructure/settings_repository.dart';
import '../infrastructure/sidecar_service.dart';

/// 実行サービス一式と、起動前に復元した設定・履歴をまとめて返す値です。
class AppRuntimeStartup {
  /// 構築済みランタイムと、GUIへ反映する初期データを生成します。
  const AppRuntimeStartup({
    required this.runtime,
    required this.settings,
    required this.history,
  });

  final AppRuntime runtime;
  final AppSettings settings;
  final List<TrackRecord> history;
}

/// 永続化、配信、DAM接続、Webリモコンの生成順と終了順を管理します。
///
/// [AppController]からOSやプロセスの詳細を隠し、サービス間の依存関係を
/// このクラスだけで組み立てます。
class AppRuntime {
  /// [create]で検証・復元済みのサービスだけを受け取りランタイムを生成します。
  AppRuntime._({
    required this.paths,
    required this.settingsRepository,
    required this.historyRepository,
    required this.manualVideos,
    required this.mediaServer,
    required this.sidecar,
    required this.remoteServer,
    required this.desktop,
    required this.onLog,
  });

  final AppPaths paths;
  final SettingsRepository settingsRepository;
  final HistoryRepository historyRepository;
  final ManualVideoStore manualVideos;
  final LocalMediaServer mediaServer;
  final SidecarService sidecar;
  final RemoteControlServer remoteServer;
  final DesktopIntegration desktop;
  final void Function(String message) onLog;

  /// アプリ用ディレクトリを確保し、保存データを含む全サービスを構築します。
  ///
  /// 構築途中の失敗時にも今回のセッションディレクトリだけは削除します。
  static Future<AppRuntimeStartup> create({
    required SidecarEventHandler onEvent,
    required PlaybackStageHandler onStage,
    required void Function(String message) onLog,
    DesktopIntegration desktop = const WindowsDesktopIntegration(),
  }) async {
    final paths = await AppPaths.create();
    try {
      return await _load(
        paths: paths,
        onEvent: onEvent,
        onStage: onStage,
        onLog: onLog,
        desktop: desktop,
      );
    } on Object {
      await paths.disposeSession();
      rethrow;
    }
  }

  /// 永続データを復元し、サービス間のコールバックを明示的に配線します。
  static Future<AppRuntimeStartup> _load({
    required AppPaths paths,
    required SidecarEventHandler onEvent,
    required PlaybackStageHandler onStage,
    required void Function(String message) onLog,
    required DesktopIntegration desktop,
  }) async {
    final settingsRepository = SettingsRepository(paths);
    final historyRepository = HistoryRepository(paths);
    final settings = await settingsRepository.load();
    final history = await historyRepository.load();
    final manualVideos = ManualVideoStore(paths);
    final storedVideos = await manualVideos.load();
    final mediaServer = LocalMediaServer(
      paths: paths,
      onStage: onStage,
      onLog: onLog,
    )..restoreManualSources(storedVideos);
    final sidecar = SidecarService(
      paths: paths,
      onEvent: onEvent,
      onLog: onLog,
    );
    final remoteServer = RemoteControlServer(
      search: (query, mode) => sidecar.searchSongs(query, mode: mode),
      readSongDetail: sidecar.songDetail,
      reserve: (token, options) => sidecar.reserveSong(token, options: options),
      favorite: (token, favorite) =>
          sidecar.updateFavorite(token, favorite: favorite),
      readState: sidecar.remoteState,
      controlPlayback: sidecar.remoteControl,
      readQueue: sidecar.remoteQueue,
      controlQueue: sidecar.remoteQueueAction,
      readHistory: () =>
          sidecar.searchSongs('', mode: RemoteSearchMode.history),
      onLog: onLog,
    );
    return AppRuntimeStartup(
      runtime: AppRuntime._(
        paths: paths,
        settingsRepository: settingsRepository,
        historyRepository: historyRepository,
        manualVideos: manualVideos,
        mediaServer: mediaServer,
        sidecar: sidecar,
        remoteServer: remoteServer,
        desktop: desktop,
        onLog: onLog,
      ),
      settings: settings,
      history: history,
    );
  }

  /// DAM向けローカル配信サーバーが待受中か返します。
  bool get serverRunning => mediaServer.isRunning;

  /// WebリモコンのLAN向けURLを返します。
  String? get remoteControlUrl => remoteServer.url;

  /// ローカル配信、DAM接続、Webリモコンの順で実行サービスを開始します。
  ///
  /// Webリモコンだけの失敗では主要機能を停止せず、診断ログへ記録します。
  Future<void> start(AppSettings settings) async {
    await mediaServer.start();
    await sidecar.start(settings);
    try {
      await remoteServer.start();
    } on Object catch (error) {
      onLog('リモコンサーバーを起動できません: $error');
    }
  }

  /// 設定を先に永続化し、その確定値を接続中のSidecarへ送ります。
  Future<void> updateSettings(AppSettings settings) async {
    await settingsRepository.save(settings);
    await sidecar.updateConfig(settings);
  }

  /// 起動中のSidecarへDAM再接続を要求します。
  void reconnect() => sidecar.reconnect();

  /// URLが確定している場合だけ、OS既定ブラウザでリモコンを開きます。
  Future<void> openRemoteControl() async {
    final url = remoteControlUrl;
    if (url != null) await desktop.openUrl(url);
  }

  /// 利用者が選んだ動画を管理領域へコピーし、次回再生用ソースへ反映します。
  Future<bool> chooseManualVideo(String videoId) async {
    final source = await desktop.chooseVideo(videoId);
    if (source == null) return false;
    final stored = await manualVideos.import(videoId, source);
    await mediaServer.setManualSource(videoId, stored);
    return true;
  }

  /// 管理領域の動画と実行中サーバーの割り当てを同時に解除します。
  Future<void> clearManualVideo(String videoId) async {
    await manualVideos.remove(videoId);
    mediaServer.clearManualSource(videoId);
  }

  /// 指定動画IDに利用可能な手動ソースがあるか返します。
  bool hasManualVideo(String videoId) => mediaServer.hasManualSource(videoId);

  /// 永続履歴だけを削除します。設定と差し替え動画には触れません。
  Future<void> clearHistory() => historyRepository.clear();

  /// 許可された履歴レコードを永続ストレージへ保存します。
  Future<void> saveHistory(Iterable<TrackRecord> records) =>
      historyRepository.save(records);

  /// 再生情報と現在設定から、DAMへ返すローカル配信ジョブを登録します。
  Future<MediaRegistration> registerMedia(
    PlaybackDescriptor descriptor,
    AppSettings settings,
  ) => mediaServer.register(descriptor, settings);

  /// Sidecarで待機中のURL置換要求へ、登録成功または公式退避の判断を返します。
  void respondToPreparation({
    required String requestId,
    required bool accepted,
    String? localUrl,
    String? error,
  }) {
    sidecar.respondToPreparation(
      requestId: requestId,
      accepted: accepted,
      localUrl: localUrl,
      error: error,
    );
  }

  /// 外部受付を止めてからプロセスと配信を終了し、最後に一時データを削除します。
  ///
  /// 途中の終了失敗が後続の清掃を妨げないよう、各処理を独立して試行します。
  Future<void> shutdown() async {
    Object? firstError;
    try {
      await remoteServer.stop();
    } on Object catch (error) {
      firstError = error;
      onLog('リモコンサーバーの終了に失敗しました: $error');
    }
    try {
      await sidecar.stop();
    } on Object catch (error) {
      firstError ??= error;
      onLog('Fridaヘルパーの終了に失敗しました: $error');
    }
    try {
      await mediaServer.stop();
    } on Object catch (error) {
      firstError ??= error;
      onLog('ローカル配信サーバーの終了に失敗しました: $error');
    }
    try {
      await paths.disposeSession();
    } on Object catch (error) {
      firstError ??= error;
      onLog('一時データの削除に失敗しました: $error');
    }
    if (firstError == null) {
      onLog('パッチを復元し、セッション一時データを削除しました');
    }
  }
}
