// Project: DAM for Windows Tools
// File: tracks.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'value_objects.dart';

class TrackRecord {
  const TrackRecord({
    required this.videoId,
    required this.artist,
    required this.title,
  });

  final String videoId;
  final String artist;
  final String title;

  TrackRecord copyWith({String? artist, String? title}) => TrackRecord(
    videoId: videoId,
    artist: artist ?? this.artist,
    title: title ?? this.title,
  );

  Map<String, String> toJson() => <String, String>{
    'videoId': videoId,
    'artist': artist,
    'title': title,
  };

  factory TrackRecord.fromJson(Map<String, dynamic> json) {
    return TrackRecord(
      videoId: normalizeVideoAssetId(json['videoId']),
      artist: sanitizeText(json['artist'], maximumLength: 300),
      title: sanitizeText(json['title'], maximumLength: 300),
    );
  }
}

enum PlaybackStage {
  detected('検知'),
  registered('登録'),
  rewritten('URL置換'),
  preparing('HLS準備'),
  manifestRequested('マニフェスト要求'),
  streaming('配信中'),
  officialFallback('公式退避'),
  failed('失敗');

  const PlaybackStage(this.label);
  final String label;
}

class TrackView {
  const TrackView({required this.record, this.stage});

  final TrackRecord record;
  final PlaybackStage? stage;

  TrackView copyWith({TrackRecord? record, PlaybackStage? stage}) =>
      TrackView(record: record ?? this.record, stage: stage ?? this.stage);
}

class MetadataCandidate {
  const MetadataCandidate({
    required this.ids,
    required this.artist,
    required this.title,
  });

  final List<String> ids;
  final String artist;
  final String title;

  factory MetadataCandidate.fromJson(Map<String, dynamic> json) {
    final rawIds = json['ids'];
    return MetadataCandidate(
      ids: rawIds is List
          ? rawIds
                .map(normalizeVideoAssetId)
                .where((id) => id.isNotEmpty)
                .toList()
          : const <String>[],
      artist: sanitizeText(json['artist'], maximumLength: 300),
      title: sanitizeText(json['title'], maximumLength: 300),
    );
  }
}
