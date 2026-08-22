// Project: DAM for Windows Tools
// File: scoring_session_state.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:collection';

import '../domain/scoring.dart';

/// 現在演奏中の1曲に限って、採点技法の回数と時系列を保持します。
class ScoringSessionState {
  static const int maximumEvents = 200;

  final LinkedHashMap<int, int> _counts = LinkedHashMap<int, int>();
  final List<ScoringEvent> _events = <ScoringEvent>[];

  bool active = false;

  /// ビブラート種別を統合した、技法ごとの検出回数を返します。
  Map<int, int> get counts => UnmodifiableMapView<int, int>(_counts);

  /// 受信順を保った採点イベントを変更不能な一覧として返します。
  List<ScoringEvent> get events => List<ScoringEvent>.unmodifiable(_events);

  /// 直近のイベントを返し、まだ受信していなければnullを返します。
  ScoringEvent? get lastEvent => _events.isEmpty ? null : _events.last;

  /// 前曲の結果を消去して新しい採点セッションを開始します。
  void begin() {
    clear();
    active = true;
  }

  /// 結果を保持したまま、セッションを非アクティブへ切り替えます。
  void deactivate() => active = false;

  /// 技法回数とイベント履歴をすべて消去します。
  void clear() {
    _counts.clear();
    _events.clear();
  }

  /// 検証済みイベントを追加し、表示回数と時系列上限を更新します。
  ///
  /// 範囲外ID、0以下の値、負の時刻はSidecar異常として受け入れません。
  bool add({
    required int techniqueId,
    required int value,
    required int timestamp,
  }) {
    if (techniqueId < 0 ||
        techniqueId >= scoringTechniqueNames.length ||
        value <= 0 ||
        timestamp < 0) {
      return false;
    }
    final canonical = canonicalScoringTechniqueId(techniqueId);
    _counts[canonical] = (_counts[canonical] ?? 0) + 1;
    _events.add(
      ScoringEvent(
        techniqueId: techniqueId,
        value: value,
        timestamp: timestamp,
      ),
    );
    if (_events.length > maximumEvents) {
      _events.removeRange(0, _events.length - maximumEvents);
    }
    active = true;
    return true;
  }
}
