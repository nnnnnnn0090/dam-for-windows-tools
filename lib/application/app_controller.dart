// Project: DAM for Windows Tools
// File: app_controller.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../domain/models.dart';
import '../infrastructure/app_paths.dart';
import '../infrastructure/manual_video_store.dart';
import '../infrastructure/media_server.dart';
import '../infrastructure/remote_control_server.dart';
import '../infrastructure/sidecar_service.dart';
import '../infrastructure/storage.dart';

class AppController extends ChangeNotifier {
  AppController();

  AppPaths? paths;
  AppStorage? storage;
  ManualVideoStore? manualVideoStore;
  LocalMediaServer? server;
  RemoteControlServer? remoteControlServer;
  SidecarService? sidecar;
  AppSettings settings = const AppSettings();

  final LinkedHashMap<String, TrackView> _tracks =
      LinkedHashMap<String, TrackView>();
  final Map<String, MetadataCandidate> _metadataById =
      <String, MetadataCandidate>{};
  final Map<String, Set<String>> _aliasesByVideoId = <String, Set<String>>{};
  final LinkedHashMap<int, int> _scoringCounts = LinkedHashMap<int, int>();
  final List<ScoringEvent> _scoringEvents = <ScoringEvent>[];
  final List<String> logs = <String>[];

  bool initialized = false;
  bool shuttingDown = false;
  String connectionCode = 'initializing';
  String connectionState = '初期化中';
  String? fatalError;
  bool scoringActive = false;

  List<TrackView> get tracks =>
      _tracks.values.toList(growable: false).reversed.toList();
  bool get serverRunning => server?.isRunning == true;
  String? get remoteControlUrl => remoteControlServer?.url;
  Map<int, int> get scoringCounts =>
      UnmodifiableMapView<int, int>(_scoringCounts);
  List<ScoringEvent> get scoringEvents =>
      List<ScoringEvent>.unmodifiable(_scoringEvents);
  ScoringEvent? get lastScoringEvent =>
      _scoringEvents.isEmpty ? null : _scoringEvents.last;

  Future<void> initialize() async {
    try {
      final resolvedPaths = await AppPaths.create();
      paths = resolvedPaths;
      final appStorage = AppStorage(resolvedPaths);
      storage = appStorage;
      settings = await appStorage.loadSettings();
      for (final record in await appStorage.loadHistory()) {
        _tracks[record.videoId] = TrackView(record: record);
      }

      final videoStore = ManualVideoStore(resolvedPaths);
      manualVideoStore = videoStore;
      final storedVideos = await videoStore.load();
      final mediaServer = LocalMediaServer(
        paths: resolvedPaths,
        onStage: markStage,
        onLog: addLog,
      );
      server = mediaServer;
      mediaServer.restoreManualSources(storedVideos);
      await mediaServer.start();

      final helper = SidecarService(
        paths: resolvedPaths,
        onEvent: _handleSidecarEvent,
        onLog: addLog,
      );
      sidecar = helper;
      await helper.start(settings);
      final remote = RemoteControlServer(
        search: (query, mode) => helper.searchSongs(query, mode: mode),
        readSongDetail: helper.songDetail,
        reserve: (token, options) =>
            helper.reserveSong(token, options: options),
        favorite: (token, favorite) =>
            helper.updateFavorite(token, favorite: favorite),
        readState: helper.remoteState,
        controlPlayback: helper.remoteControl,
        readQueue: helper.remoteQueue,
        controlQueue: helper.remoteQueueAction,
        readHistory: () =>
            helper.searchSongs('', mode: RemoteSearchMode.history),
        onLog: addLog,
      );
      remoteControlServer = remote;
      try {
        await remote.start();
      } on Object catch (error) {
        addLog('リモコンサーバーを起動できません: $error');
      }
      initialized = true;
      connectionCode = 'monitoring';
      connectionState = 'DAMを監視中';
      addLog('${AppConfig.productName}を起動しました');
    } on Object catch (error, stackTrace) {
      fatalError = error.toString();
      connectionCode = 'failed';
      connectionState = '初期化失敗';
      addLog('初期化に失敗しました: $error\n$stackTrace');
    }
    notifyListeners();
  }

  Future<void> updateSettings(AppSettings next) async {
    settings = next.copyWith(skipMs: next.skipMs.clamp(0, 30000));
    notifyListeners();
    await storage?.saveSettings(settings);
    await sidecar?.updateConfig(settings);
  }

  Future<void> reconnect() async {
    sidecar?.reconnect();
  }

  Future<void> openRemoteControl() async {
    final url = remoteControlUrl;
    if (url == null) return;
    try {
      await Process.start('explorer.exe', <String>[
        url,
      ], mode: ProcessStartMode.detached);
    } on Object catch (error) {
      addLog('リモコンをブラウザで開けません: $error');
    }
  }

  @visibleForTesting
  Future<void> handleSidecarEventForTest(Map<String, dynamic> event) =>
      _handleSidecarEvent(event);

  Future<void> chooseManualVideo(String videoId) async {
    final result = await FilePicker.pickFile(
      dialogTitle: '$videoId の差し替え動画を選択',
      type: FileType.custom,
      allowedExtensions: ManualVideoStore.supportedExtensions,
    );
    final selected = result?.path;
    if (selected == null) return;
    try {
      final stored = await manualVideoStore!.import(videoId, File(selected));
      await server?.setManualSource(videoId, stored);
      addLog('[$videoId] 差し替え動画をデータフォルダへ保存しました');
      notifyListeners();
    } on Object catch (error) {
      addLog('[$videoId] GUI動画の設定に失敗しました: $error');
      rethrow;
    }
  }

  Future<void> clearManualVideo(String videoId) async {
    try {
      await manualVideoStore?.remove(videoId);
      server?.clearManualSource(videoId);
      addLog('[$videoId] 保存済みの差し替え動画を削除しました');
      notifyListeners();
    } on Object catch (error) {
      addLog('[$videoId] 差し替え動画を削除できません: $error');
    }
  }

  bool hasManualVideo(String videoId) =>
      server?.hasManualSource(videoId) == true;

  Future<void> clearHistory() async {
    _tracks.clear();
    _aliasesByVideoId.clear();
    await storage?.clearHistory();
    addLog('曲情報の履歴を消去しました');
    notifyListeners();
  }

  void clearScoringSession() {
    _scoringCounts.clear();
    _scoringEvents.clear();
    notifyListeners();
  }

  void markStage(String videoId, PlaybackStage stage, String detail) {
    final current = _tracks[videoId];
    if (current != null) {
      _tracks[videoId] = current.copyWith(stage: stage);
    }
    addLog('[$videoId] ${stage.label}: $detail');
    notifyListeners();
  }

  void addLog(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 23);
    logs.add('$timestamp $message');
    if (logs.length > 500) logs.removeRange(0, logs.length - 500);
    notifyListeners();
  }

  Future<void> shutdown() async {
    if (shuttingDown) return;
    shuttingDown = true;
    notifyListeners();
    Object? firstError;
    try {
      await remoteControlServer?.stop();
    } on Object catch (error) {
      firstError = error;
      addLog('リモコンサーバーの終了に失敗しました: $error');
    }
    try {
      await sidecar?.stop();
    } on Object catch (error) {
      firstError = error;
      addLog('Fridaヘルパーの終了に失敗しました: $error');
    }
    try {
      await server?.stop();
    } on Object catch (error) {
      firstError ??= error;
      addLog('ローカル配信サーバーの終了に失敗しました: $error');
    }
    try {
      await paths?.disposeSession();
    } on Object catch (error) {
      firstError ??= error;
      addLog('一時データの削除に失敗しました: $error');
    }
    if (firstError == null) {
      addLog('パッチを復元し、セッション一時データを削除しました');
    }
  }

  Future<void> _handleSidecarEvent(Map<String, dynamic> event) async {
    final type = event['type']?.toString() ?? '';
    switch (type) {
      case 'log':
        addLog(event['message']?.toString() ?? '');
      case 'status':
        connectionCode = event['state']?.toString() ?? 'unknown';
        connectionState =
            event['detail']?.toString() ?? event['state']?.toString() ?? '状態不明';
        if (connectionCode != 'attached') scoringActive = false;
        notifyListeners();
      case 'metadata':
        _acceptMetadata(event);
      case 'playback':
        await _acceptPlayback(PlaybackDescriptor.fromJson(event));
      case 'prepare':
        await _prepareReplacement(event);
      case 'rewritten':
        final descriptor = PlaybackDescriptor.fromJson(event);
        if (descriptor.videoId.isNotEmpty) {
          markStage(descriptor.videoId, PlaybackStage.rewritten, 'プレイヤー引数を置換');
        }
      case 'patch-error':
        addLog('パッチ検証エラー: ${event['message'] ?? 'unknown'}');
      case 'scoring-start':
        _beginScoringSession();
      case 'scoring-technique':
        _acceptScoringTechnique(event);
      case 'scoring-stop':
        _finishScoringSession();
      default:
        if (type.isNotEmpty) addLog('未処理イベント: $type');
    }
  }

  void _beginScoringSession() {
    _scoringCounts.clear();
    _scoringEvents.clear();
    scoringActive = true;
    addLog('採点セッションを開始しました');
  }

  void _acceptScoringTechnique(Map<String, dynamic> event) {
    final rawTechnique = event['technique'];
    final rawValue = event['value'];
    final rawTimestamp = event['timestamp'];
    if (rawTechnique is! num || rawValue is! num || rawTimestamp is! num) {
      return;
    }
    final technique = rawTechnique.toInt();
    final value = rawValue.toInt();
    final timestamp = rawTimestamp.toInt();
    if (technique < 0 ||
        technique >= scoringTechniqueNames.length ||
        value <= 0 ||
        timestamp < 0) {
      return;
    }
    final canonical = canonicalScoringTechniqueId(technique);
    _scoringCounts[canonical] = (_scoringCounts[canonical] ?? 0) + 1;
    _scoringEvents.add(
      ScoringEvent(techniqueId: technique, value: value, timestamp: timestamp),
    );
    if (_scoringEvents.length > 200) {
      _scoringEvents.removeRange(0, _scoringEvents.length - 200);
    }
    scoringActive = true;
    notifyListeners();
  }

  void _finishScoringSession() {
    if (!scoringActive) return;
    scoringActive = false;
    addLog('採点セッションを終了しました');
  }

  void _acceptMetadata(Map<String, dynamic> event) {
    final rawCandidates = event['candidates'];
    if (rawCandidates is! List) return;
    var changed = false;
    for (final raw in rawCandidates) {
      if (raw is! Map<String, dynamic>) continue;
      final candidate = MetadataCandidate.fromJson(raw);
      if (candidate.ids.isEmpty ||
          (candidate.artist.isEmpty && candidate.title.isEmpty)) {
        continue;
      }
      for (final id in candidate.ids) {
        _metadataById[id] = candidate;
      }
      for (final entry in _aliasesByVideoId.entries) {
        if (candidate.ids.any(entry.value.contains)) {
          changed = _updateTrackMetadata(entry.key, candidate) || changed;
        }
      }
    }
    if (changed) unawaited(_persistHistory());
    notifyListeners();
  }

  Future<void> _acceptPlayback(PlaybackDescriptor descriptor) async {
    final videoId = _safeId(descriptor.videoId);
    if (videoId.isEmpty) {
      addLog('再生を検知しましたが動画IDを確定できませんでした');
      return;
    }
    final aliases = <String>{videoId};
    _aliasesByVideoId[videoId] = aliases;
    MetadataCandidate? metadata;
    for (final id in aliases) {
      metadata = _metadataById[id];
      if (metadata != null) break;
    }
    final existing = _tracks[videoId]?.record;
    final record = TrackRecord(
      videoId: videoId,
      artist: metadata?.artist.isNotEmpty == true
          ? metadata!.artist
          : existing?.artist ?? '',
      title: metadata?.title.isNotEmpty == true
          ? metadata!.title
          : existing?.title ?? '',
    );
    _tracks[videoId] = TrackView(record: record, stage: PlaybackStage.detected);
    addLog('[$videoId] 最終プレイヤー経路で再生を検知しました');
    await _persistHistory();
    notifyListeners();
  }

  Future<void> _prepareReplacement(Map<String, dynamic> event) async {
    final requestId = event['requestId']?.toString() ?? '';
    final descriptor = PlaybackDescriptor.fromJson(event);
    if (requestId.isEmpty || server == null) return;
    try {
      final registration = await server!.register(descriptor, settings);
      sidecar?.respondToPreparation(
        requestId: requestId,
        accepted: true,
        localUrl: registration.localUrl,
      );
    } on Object catch (error) {
      sidecar?.respondToPreparation(
        requestId: requestId,
        accepted: false,
        error: error.toString(),
      );
      final videoId = _safeId(descriptor.videoId);
      if (videoId.isNotEmpty) {
        markStage(videoId, PlaybackStage.officialFallback, '登録失敗: $error');
      }
    }
  }

  bool _updateTrackMetadata(String videoId, MetadataCandidate metadata) {
    final current = _tracks[videoId];
    if (current == null) return false;
    final next = current.record.copyWith(
      artist: metadata.artist.isNotEmpty ? metadata.artist : null,
      title: metadata.title.isNotEmpty ? metadata.title : null,
    );
    if (next.artist == current.record.artist &&
        next.title == current.record.title) {
      return false;
    }
    _tracks[videoId] = current.copyWith(record: next);
    return true;
  }

  Future<void> _persistHistory() async {
    await storage?.saveHistory(_tracks.values.map((view) => view.record));
  }

  static String _safeId(String value) {
    return normalizeVideoAssetId(value);
  }
}
