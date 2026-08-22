// Project: DAM for Windows Tools
// File: application_state_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:dam_for_windows_tools/application/diagnostic_log.dart';
import 'package:dam_for_windows_tools/application/scoring_session_state.dart';
import 'package:dam_for_windows_tools/application/track_history_state.dart';
import 'package:dam_for_windows_tools/domain/scoring.dart';
import 'package:dam_for_windows_tools/domain/tracks.dart';
import 'package:flutter_test/flutter_test.dart';

/// 履歴・採点・診断ログの、セッション内状態管理を検証します。
void main() {
  test(
    'track history adds only playback and updates exact metadata aliases',
    () {
      final state = TrackHistoryState()
        ..restore(const <TrackRecord>[
          TrackRecord(videoId: '6184-92', artist: '', title: ''),
        ]);

      expect(state.registerPlayback('6184-92')?.videoId, '6184-92');
      expect(state.registerPlayback('7663-96')?.videoId, '7663-96');
      expect(
        state.acceptMetadata(const <MetadataCandidate>[
          MetadataCandidate(
            ids: <String>['6184-92', 'internal-1'],
            artist: '米津玄師',
            title: 'Lemon',
          ),
        ]),
        isTrue,
      );
      expect(state.records.first.artist, '米津玄師');
      expect(state.records.first.title, 'Lemon');
      expect(state.records, hasLength(2));
    },
  );

  test('scoring session accepts canonical techniques and caps events', () {
    final state = ScoringSessionState()..begin();
    expect(
      state.add(
        techniqueId: canonicalScoringTechniqueIds.first,
        value: 1,
        timestamp: 10,
      ),
      isTrue,
    );
    expect(state.add(techniqueId: -1, value: 1, timestamp: 11), isFalse);
    expect(state.counts[canonicalScoringTechniqueIds.first], 1);
    expect(state.lastEvent?.timestamp, 10);
    state.deactivate();
    expect(state.active, isFalse);
    expect(state.add(techniqueId: 0, value: 1, timestamp: 12), isTrue);
    expect(state.active, isTrue);
  });

  test('diagnostic log keeps only its bounded tail', () {
    final log = DiagnosticLog(maximumEntries: 3);
    for (var index = 0; index < 5; index++) {
      log.add('entry-$index');
    }
    expect(log.entries, hasLength(3));
    expect(log.entries.first, contains('entry-2'));
    expect(log.entries.last, contains('entry-4'));
  });
}
