// Project: DAM for Windows Tools
// File: app_controller.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../domain/app_settings.dart';
import '../domain/app_update.dart';
import '../domain/playback.dart';
import '../domain/scoring.dart';
import '../domain/tracks.dart';
import '../domain/value_objects.dart';
import 'app_runtime.dart';
import 'diagnostic_log.dart';
import 'scoring_session_state.dart';
import 'track_history_state.dart';

/// GUIが監視するアプリ全体の状態と、利用者操作の入口を提供します。
///
/// 表示層にはインフラ実装を直接見せず、Sidecarイベントを履歴・採点・配信の
/// 各状態へ振り分けるアプリケーション層の調整役です。
class AppController extends ChangeNotifier {
  /// 未初期化のコントローラーを生成します。実サービスの構築は[initialize]で行います。
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
  AppUpdatePhase updatePhase = AppUpdatePhase.idle;
  AppUpdate? availableUpdate;
  String updateStatus = '更新を確認';
  int updateProgressPercent = 0;
  Future<AppUpdate?>? _updateCheck;
  bool _updatePromptOpen = false;

  /// 現在の曲で採点イベントを受信中か返します。
  bool get scoringActive => _scoring.active;

  /// 永続履歴と現在セッションの配信状態をまとめた表示行を返します。
  List<TrackView> get tracks => _history.views;

  /// ローカル動画配信サーバーが要求を受けられる状態か返します。
  bool get serverRunning => _runtime?.serverRunning == true;

  /// 同一LANの端末から開くWebリモコンURLを返します。
  String? get remoteControlUrl => _runtime?.remoteControlUrl;

  /// 配布フォルダから起動しており、自動更新を安全に実行できるか返します。
  bool get updatesSupported => _runtime?.updatesSupported == true;

  /// 更新確認またはダウンロード中で、同じ操作を重ねてはいけないか返します。
  bool get updateBusy =>
      updatePhase == AppUpdatePhase.checking ||
      updatePhase == AppUpdatePhase.downloading ||
      updatePhase == AppUpdatePhase.restarting;

  /// 技法別の検出回数を、変更できない参照として返します。
  Map<int, int> get scoringCounts => _scoring.counts;

  /// 現在の採点セッションで受信した時系列イベントを返します。
  List<ScoringEvent> get scoringEvents => _scoring.events;

  /// 採点表示の即時更新に使う、直近の技法イベントを返します。
  ScoringEvent? get lastScoringEvent => _scoring.lastEvent;

  /// 診断ダイアログへ表示する、上限管理済みログを返します。
  List<String> get logs => _diagnostics.entries;

  /// 永続データと各サービスを構築し、DAM監視を開始します。
  ///
  /// 途中で失敗した場合は生成済みサービスを終了し、GUIには致命エラーを残します。
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
      try {
        final previousUpdateFailure = await startup.runtime
            .takeLastUpdateFailure();
        if (previousUpdateFailure != null && previousUpdateFailure.isNotEmpty) {
          addLog('前回の自動更新に失敗し、旧版へ復元しました: $previousUpdateFailure');
        }
      } on Object catch (error) {
        addLog('自動更新の作業履歴を確認できません: $error');
      }
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

  /// 正規化した設定を保存し、接続中のSidecarへ即時反映します。
  Future<void> updateSettings(AppSettings next) async {
    settings = next.normalized();
    notifyListeners();
    await _runtime?.updateSettings(settings);
  }

  /// DAMとの接続だけを張り直し、GUIやローカルサーバーは維持します。
  Future<void> reconnect() async {
    _runtime?.reconnect();
  }

  /// OS既定ブラウザでWebリモコンを開き、失敗時は診断ログへ記録します。
  Future<void> openRemoteControl() async {
    try {
      await _runtime?.openRemoteControl();
    } on Object catch (error) {
      addLog('リモコンをブラウザで開けません: $error');
    }
  }

  /// GitHub Releasesの確認を1本へ束ね、GUIへ最新版または失敗状態を反映します。
  Future<AppUpdate?> checkForUpdates() {
    final activeCheck = _updateCheck;
    if (activeCheck != null) return activeCheck;
    late final Future<AppUpdate?> request;
    request = _performUpdateCheck().whenComplete(() {
      if (identical(_updateCheck, request)) _updateCheck = null;
    });
    _updateCheck = request;
    return request;
  }

  /// 更新確認ダイアログの多重表示を防ぎ、表示権を最初の画面だけへ渡します。
  bool beginUpdatePrompt() {
    if (_updatePromptOpen) return false;
    _updatePromptOpen = true;
    return true;
  }

  /// 更新確認ダイアログを閉じ、次回の手動確認を許可します。
  void endUpdatePrompt() {
    _updatePromptOpen = false;
  }

  /// 選択中の更新を検証付きで取得し、サービス停止後に更新プロセスへ引き継ぎます。
  Future<void> installAvailableUpdate() async {
    final update = availableUpdate;
    final runtime = _runtime;
    if (update == null || runtime == null || updateBusy) return;
    updatePhase = AppUpdatePhase.downloading;
    updateStatus = 'v${update.version} をダウンロード中';
    updateProgressPercent = 0;
    notifyListeners();
    try {
      await runtime.prepareUpdate(update, onProgress: _acceptUpdateProgress);
      updatePhase = AppUpdatePhase.restarting;
      updateStatus = '更新して再起動します';
      notifyListeners();
      await shutdown();
      exit(0);
    } on Object catch (error, stackTrace) {
      updatePhase = AppUpdatePhase.failed;
      updateStatus = '更新失敗';
      addLog('自動更新に失敗しました: $error\n$stackTrace');
      notifyListeners();
    }
  }

  /// テストから実際と同じイベント振り分け経路を呼び出します。
  @visibleForTesting
  Future<void> handleSidecarEventForTest(Map<String, dynamic> event) =>
      _handleSidecarEvent(event);

  /// 選択された動画をアプリ管理領域へ取り込み、指定IDの次回再生へ割り当てます。
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

  /// 指定IDに保存した差し替え動画を削除し、以後は公式動画へ戻します。
  Future<void> clearManualVideo(String videoId) async {
    try {
      await _runtime?.clearManualVideo(videoId);
      addLog('[$videoId] 保存済みの差し替え動画を削除しました');
      notifyListeners();
    } on Object catch (error) {
      addLog('[$videoId] 差し替え動画を削除できません: $error');
    }
  }

  /// 指定IDに、現在利用可能な差し替え動画が登録されているか返します。
  bool hasManualVideo(String videoId) =>
      _runtime?.hasManualVideo(videoId) == true;

  /// 曲情報だけの再生履歴をメモリと永続ストレージの両方から消去します。
  Future<void> clearHistory() async {
    _history.clear();
    await _runtime?.clearHistory();
    addLog('曲情報の履歴を消去しました');
    notifyListeners();
  }

  /// 現在表示中の採点回数とイベントだけを消去します。
  void clearScoringSession() {
    _scoring.clear();
    notifyListeners();
  }

  /// 指定動画の配信段階を更新し、同じ内容を診断ログにも残します。
  void markStage(String videoId, PlaybackStage stage, String detail) {
    _history.markStage(videoId, stage);
    addLog('[$videoId] ${stage.label}: $detail');
    notifyListeners();
  }

  /// 時刻付き診断ログを追加し、ログ表示中のGUIへ変更を通知します。
  void addLog(String message) {
    _diagnostics.add(message);
    notifyListeners();
  }

  /// 多重実行を防ぎながら、パッチ復元を含む全サービス終了処理を開始します。
  Future<void> shutdown() async {
    if (shuttingDown) return;
    shuttingDown = true;
    notifyListeners();
    await _runtime?.shutdown();
  }

  /// 更新サーバーの応答をアプリ状態へ変換し、ネットワーク失敗は主要機能と分離します。
  Future<AppUpdate?> _performUpdateCheck() async {
    final runtime = _runtime;
    if (runtime == null || !runtime.updatesSupported) {
      updatePhase = AppUpdatePhase.failed;
      updateStatus = '配布版でのみ更新できます';
      notifyListeners();
      return null;
    }
    updatePhase = AppUpdatePhase.checking;
    updateStatus = '更新を確認中';
    notifyListeners();
    try {
      final update = await runtime.checkForUpdate();
      if (shuttingDown) return null;
      availableUpdate = update;
      if (update == null) {
        updatePhase = AppUpdatePhase.latest;
        updateStatus = '最新版です';
      } else {
        updatePhase = AppUpdatePhase.available;
        updateStatus = 'v${update.version} に更新';
      }
      notifyListeners();
      return update;
    } on Object catch (error) {
      if (shuttingDown) return null;
      updatePhase = AppUpdatePhase.failed;
      updateStatus = '更新確認に失敗';
      addLog('更新情報を確認できません: $error');
      notifyListeners();
      return null;
    }
  }

  /// ダウンロード進捗を1%単位に丸め、過剰なGUI再描画を防ぎます。
  void _acceptUpdateProgress(double progress) {
    final percent = (progress.clamp(0, 1) * 100).floor();
    if (percent == updateProgressPercent) return;
    updateProgressPercent = percent;
    updateStatus = '更新をダウンロード中 $percent%';
    notifyListeners();
  }

  /// Sidecarから届く型付きイベントを、対応するアプリ状態へ振り分けます。
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

  /// 前曲の採点結果を破棄して、新しい採点セッションを開始します。
  void _beginScoringSession() {
    _scoring.begin();
    addLog('採点セッションを開始しました');
  }

  /// 数値検証を通った技法通知だけを現在の採点セッションへ追加します。
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

  /// 採点結果を画面に残したまま、追加イベントの受付状態を終了します。
  void _finishScoringSession() {
    if (!_scoring.active) return;
    _scoring.deactivate();
    addLog('採点セッションを終了しました');
  }

  /// DAMから読み取った曲情報をID完全一致で履歴へ反映し、変更時だけ保存します。
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

  /// 最終プレイヤー経路で確定した公開動画IDを、初めて再生履歴へ登録します。
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

  /// Sidecarの同期準備要求に対し、ローカル配信URLを登録して結果を返します。
  ///
  /// 登録に失敗しても公式URLへ退避できるよう、拒否応答と状態更新を必ず行います。
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

  /// 現在の履歴から永続化対象3項目だけを保存します。
  Future<void> _persistHistory() async {
    await _runtime?.saveHistory(_history.records);
  }

  /// 信頼できないイベント値を公開動画ID形式へ限定します。
  static String _safeId(String value) {
    return normalizeVideoAssetId(value);
  }
}
