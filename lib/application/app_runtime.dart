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

class AppRuntimeStartup {
  const AppRuntimeStartup({
    required this.runtime,
    required this.settings,
    required this.history,
  });

  final AppRuntime runtime;
  final AppSettings settings;
  final List<TrackRecord> history;
}

class AppRuntime {
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

  bool get serverRunning => mediaServer.isRunning;
  String? get remoteControlUrl => remoteServer.url;

  Future<void> start(AppSettings settings) async {
    await mediaServer.start();
    await sidecar.start(settings);
    try {
      await remoteServer.start();
    } on Object catch (error) {
      onLog('リモコンサーバーを起動できません: $error');
    }
  }

  Future<void> updateSettings(AppSettings settings) async {
    await settingsRepository.save(settings);
    await sidecar.updateConfig(settings);
  }

  void reconnect() => sidecar.reconnect();

  Future<void> openRemoteControl() async {
    final url = remoteControlUrl;
    if (url != null) await desktop.openUrl(url);
  }

  Future<bool> chooseManualVideo(String videoId) async {
    final source = await desktop.chooseVideo(videoId);
    if (source == null) return false;
    final stored = await manualVideos.import(videoId, source);
    await mediaServer.setManualSource(videoId, stored);
    return true;
  }

  Future<void> clearManualVideo(String videoId) async {
    await manualVideos.remove(videoId);
    mediaServer.clearManualSource(videoId);
  }

  bool hasManualVideo(String videoId) => mediaServer.hasManualSource(videoId);

  Future<void> clearHistory() => historyRepository.clear();

  Future<void> saveHistory(Iterable<TrackRecord> records) =>
      historyRepository.save(records);

  Future<MediaRegistration> registerMedia(
    PlaybackDescriptor descriptor,
    AppSettings settings,
  ) => mediaServer.register(descriptor, settings);

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
