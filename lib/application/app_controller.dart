// Project: DAM for Windows Tools
// File: app_controller.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../domain/app_settings.dart';
import '../domain/playback.dart';
import '../domain/scoring.dart';
import '../domain/tracks.dart';
import '../domain/value_objects.dart';
import 'app_runtime.dart';
import 'diagnostic_log.dart';
import 'scoring_session_state.dart';
import 'track_history_state.dart';

class AppController extends ChangeNotifier {
  AppController();

  AppRuntime? _runtime;
  AppSettings settings = const AppSettings();

  final TrackHistoryState _history = TrackHistoryState();
  final ScoringSessionState _scoring = ScoringSessionState();
  final DiagnosticLog _diagnostics = DiagnosticLog();

  bool initialized = false;
  bool shuttingDown = false;
  String connectionCode = 'initializing';
  String connectionState = '初期化中';
  String? fatalError;
  bool get scoringActive => _scoring.active;

  List<TrackView> get tracks => _history.views;
  bool get serverRunning => _runtime?.serverRunning == true;
  String? get remoteControlUrl => _runtime?.remoteControlUrl;
  Map<int, int> get scoringCounts => _scoring.counts;
  List<ScoringEvent> get scoringEvents => _scoring.events;
  ScoringEvent? get lastScoringEvent => _scoring.lastEvent;
  List<String> get logs => _diagnostics.entries;

  Future<void> initialize() async {
    try {
      final startup = await AppRuntime.create(
        onEvent: _handleSidecarEvent,
        onStage: markStage,
        onLog: addLog,
      );
      _runtime = startup.runtime;
      settings = startup.settings;
      _history.restore(startup.history);
      await startup.runtime.start(settings);
      initialized = true;
      connectionCode = 'monitoring';
      connectionState = 'DAMを監視中';
      addLog('${AppConfig.productName}を起動しました');
    } on Object catch (error, stackTrace) {
      await _runtime?.shutdown();
      _runtime = null;
      fatalError = error.toString();
      connectionCode = 'failed';
      connectionState = '初期化失敗';
      addLog('初期化に失敗しました: $error\n$stackTrace');
    }
    notifyListeners();
  }

  Future<void> updateSettings(AppSettings next) async {
    settings = next.normalized();
    notifyListeners();
    await _runtime?.updateSettings(settings);
  }

  Future<void> reconnect() async {
    _runtime?.reconnect();
  }

  Future<void> openRemoteControl() async {
    try {
      await _runtime?.openRemoteControl();
    } on Object catch (error) {
      addLog('リモコンをブラウザで開けません: $error');
    }
  }

  @visibleForTesting
  Future<void> handleSidecarEventForTest(Map<String, dynamic> event) =>
      _handleSidecarEvent(event);

  Future<void> chooseManualVideo(String videoId) async {
    try {
      final changed = await _runtime?.chooseManualVideo(videoId) == true;
      if (!changed) return;
      addLog('[$videoId] 差し替え動画をデータフォルダへ保存しました');
      notifyListeners();
    } on Object catch (error) {
      addLog('[$videoId] GUI動画の設定に失敗しました: $error');
      rethrow;
    }
  }

  Future<void> clearManualVideo(String videoId) async {
    try {
      await _runtime?.clearManualVideo(videoId);
      addLog('[$videoId] 保存済みの差し替え動画を削除しました');
      notifyListeners();
    } on Object catch (error) {
      addLog('[$videoId] 差し替え動画を削除できません: $error');
    }
  }

  bool hasManualVideo(String videoId) =>
      _runtime?.hasManualVideo(videoId) == true;

  Future<void> clearHistory() async {
    _history.clear();
    await _runtime?.clearHistory();
    addLog('曲情報の履歴を消去しました');
    notifyListeners();
  }

  void clearScoringSession() {
    _scoring.clear();
    notifyListeners();
  }

  void markStage(String videoId, PlaybackStage stage, String detail) {
    _history.markStage(videoId, stage);
    addLog('[$videoId] ${stage.label}: $detail');
    notifyListeners();
  }

  void addLog(String message) {
    _diagnostics.add(message);
    notifyListeners();
  }

  Future<void> shutdown() async {
    if (shuttingDown) return;
    shuttingDown = true;
    notifyListeners();
    await _runtime?.shutdown();
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
        if (connectionCode != 'attached') _scoring.deactivate();
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
    _scoring.begin();
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
    if (_scoring.add(
      techniqueId: technique,
      value: value,
      timestamp: timestamp,
    )) {
      notifyListeners();
    }
  }

  void _finishScoringSession() {
    if (!_scoring.active) return;
    _scoring.deactivate();
    addLog('採点セッションを終了しました');
  }

  void _acceptMetadata(Map<String, dynamic> event) {
    final rawCandidates = event['candidates'];
    if (rawCandidates is! List) return;
    final candidates = <MetadataCandidate>[];
    for (final raw in rawCandidates) {
      if (raw is! Map<String, dynamic>) continue;
      candidates.add(MetadataCandidate.fromJson(raw));
    }
    final changed = _history.acceptMetadata(candidates);
    if (changed) unawaited(_persistHistory());
    notifyListeners();
  }

  Future<void> _acceptPlayback(PlaybackDescriptor descriptor) async {
    final videoId = _safeId(descriptor.videoId);
    if (videoId.isEmpty) {
      addLog('再生を検知しましたが動画IDを確定できませんでした');
      return;
    }
    _history.registerPlayback(videoId);
    addLog('[$videoId] 最終プレイヤー経路で再生を検知しました');
    await _persistHistory();
    notifyListeners();
  }

  Future<void> _prepareReplacement(Map<String, dynamic> event) async {
    final requestId = event['requestId']?.toString() ?? '';
    final descriptor = PlaybackDescriptor.fromJson(event);
    final runtime = _runtime;
    if (requestId.isEmpty || runtime == null) return;
    try {
      final registration = await runtime.registerMedia(descriptor, settings);
      runtime.respondToPreparation(
        requestId: requestId,
        accepted: true,
        localUrl: registration.localUrl,
      );
    } on Object catch (error) {
      runtime.respondToPreparation(
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

  Future<void> _persistHistory() async {
    await _runtime?.saveHistory(_history.records);
  }

  static String _safeId(String value) {
    return normalizeVideoAssetId(value);
  }
}
