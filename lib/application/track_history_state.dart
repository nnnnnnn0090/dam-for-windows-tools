// Project: DAM for Windows Tools
// File: track_history_state.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:collection';

import '../domain/tracks.dart';
import '../domain/value_objects.dart';

class TrackHistoryState {
  final LinkedHashMap<String, TrackView> _tracks =
      LinkedHashMap<String, TrackView>();
  final Map<String, MetadataCandidate> _metadataById =
      <String, MetadataCandidate>{};
  final Map<String, Set<String>> _aliasesByVideoId = <String, Set<String>>{};

  List<TrackView> get views =>
      _tracks.values.toList(growable: false).reversed.toList(growable: false);

  Iterable<TrackRecord> get records =>
      _tracks.values.map((view) => view.record);

  void restore(Iterable<TrackRecord> records) {
    _tracks.clear();
    for (final record in records) {
      if (record.videoId.isNotEmpty) {
        _tracks[record.videoId] = TrackView(record: record);
      }
    }
  }

  void clear() {
    _tracks.clear();
    _aliasesByVideoId.clear();
  }

  bool markStage(String rawVideoId, PlaybackStage stage) {
    final videoId = normalizeVideoAssetId(rawVideoId);
    final current = _tracks[videoId];
    if (current == null) return false;
    _tracks[videoId] = current.copyWith(stage: stage);
    return true;
  }

  TrackRecord? registerPlayback(String rawVideoId) {
    final videoId = normalizeVideoAssetId(rawVideoId);
    if (videoId.isEmpty) return null;
    final aliases = <String>{videoId};
    _aliasesByVideoId[videoId] = aliases;
    final metadata = aliases
        .map((id) => _metadataById[id])
        .whereType<MetadataCandidate>()
        .firstOrNull;
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
    return record;
  }

  bool acceptMetadata(Iterable<MetadataCandidate> candidates) {
    var changed = false;
    for (final candidate in candidates) {
      if (candidate.ids.isEmpty ||
          (candidate.artist.isEmpty && candidate.title.isEmpty)) {
        continue;
      }
      for (final id in candidate.ids) {
        _metadataById[id] = candidate;
      }
      for (final entry in _aliasesByVideoId.entries) {
        if (candidate.ids.any(entry.value.contains)) {
          changed = _updateMetadata(entry.key, candidate) || changed;
        }
      }
    }
    return changed;
  }

  bool _updateMetadata(String videoId, MetadataCandidate metadata) {
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
}
