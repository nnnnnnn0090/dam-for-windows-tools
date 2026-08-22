// Project: DAM for Windows Tools
// File: scoring_session_state.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:collection';

import '../domain/scoring.dart';

class ScoringSessionState {
  static const int maximumEvents = 200;

  final LinkedHashMap<int, int> _counts = LinkedHashMap<int, int>();
  final List<ScoringEvent> _events = <ScoringEvent>[];

  bool active = false;

  Map<int, int> get counts => UnmodifiableMapView<int, int>(_counts);
  List<ScoringEvent> get events => List<ScoringEvent>.unmodifiable(_events);
  ScoringEvent? get lastEvent => _events.isEmpty ? null : _events.last;

  void begin() {
    clear();
    active = true;
  }

  void deactivate() => active = false;

  void clear() {
    _counts.clear();
    _events.clear();
  }

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
