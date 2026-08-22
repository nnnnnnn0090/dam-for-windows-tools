// Project: DAM for Windows Tools
// File: track_history_state.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:collection';

import '../domain/tracks.dart';
import '../domain/value_objects.dart';

/// 再生確定後の履歴と、後着する曲情報・一時的な配信状態を関連付けます。
///
/// 曲一覧を見ただけでは履歴を作らず、[registerPlayback]を呼んだ公開動画IDに
/// 完全一致するメタデータだけを反映します。
class TrackHistoryState {
  final LinkedHashMap<String, TrackView> _tracks =
      LinkedHashMap<String, TrackView>();
  final Map<String, MetadataCandidate> _metadataById =
      <String, MetadataCandidate>{};
  final Map<String, Set<String>> _aliasesByVideoId = <String, Set<String>>{};

  /// GUI表示用に、新しい再生を先頭へ並べた履歴を返します。
  List<TrackView> get views =>
      _tracks.values.toList(growable: false).reversed.toList(growable: false);

  /// 永続化可能な曲情報だけを、登録順を保って返します。
  Iterable<TrackRecord> get records =>
      _tracks.values.map((view) => view.record);

  /// 保存済み履歴を読み込み、現在セッションだけの配信状態は付けずに復元します。
  void restore(Iterable<TrackRecord> records) {
    _tracks.clear();
    for (final record in records) {
      if (record.videoId.isNotEmpty) {
        _tracks[record.videoId] = TrackView(record: record);
      }
    }
  }

  /// 履歴と再生中のID対応を消去し、未再生曲の収集メタデータは再利用します。
  void clear() {
    _tracks.clear();
    _aliasesByVideoId.clear();
  }

  /// 既に再生履歴へ登録された動画だけ、現在の配信段階を更新します。
  bool markStage(String rawVideoId, PlaybackStage stage) {
    final videoId = normalizeVideoAssetId(rawVideoId);
    final current = _tracks[videoId];
    if (current == null) return false;
    _tracks[videoId] = current.copyWith(stage: stage);
    return true;
  }

  /// 最終プレイヤー経路で確定したIDを履歴へ追加し、一致済み曲情報を反映します。
  ///
  /// 同じIDの再生は行を重複させず、既存の曲情報を保持して状態だけ更新します。
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

  /// DAMから収集した曲情報をID別に保管し、再生済みの完全一致行だけ更新します。
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

  /// 空でない項目だけを既存履歴へ反映し、実際に変化したか返します。
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
