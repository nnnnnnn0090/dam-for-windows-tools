// Project: DAM for Windows Tools
// File: models.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:convert';

final RegExp _videoAssetIdPattern = RegExp(r'^[0-9A-Za-z]+-[0-9A-Za-z_-]+$');

String normalizeVideoAssetId(Object? value) {
  if (value is! String) return '';
  final text = value.trim();
  return text.length <= 128 && _videoAssetIdPattern.hasMatch(text) ? text : '';
}

class AppSettings {
  const AppSettings({
    this.disableModuleCheck = true,
    this.disableForegroundCheck = true,
    this.replaceVideoUrls = true,
    this.scoringEnabled = true,
    this.skipEnabled = true,
    this.skipMs = 150,
  });

  final bool disableModuleCheck;
  final bool disableForegroundCheck;
  final bool replaceVideoUrls;
  final bool scoringEnabled;
  final bool skipEnabled;
  final int skipMs;

  int get effectiveSkipMs => skipEnabled ? skipMs.clamp(0, 30000) : 0;

  AppSettings copyWith({
    bool? disableModuleCheck,
    bool? disableForegroundCheck,
    bool? replaceVideoUrls,
    bool? scoringEnabled,
    bool? skipEnabled,
    int? skipMs,
  }) {
    return AppSettings(
      disableModuleCheck: disableModuleCheck ?? this.disableModuleCheck,
      disableForegroundCheck:
          disableForegroundCheck ?? this.disableForegroundCheck,
      replaceVideoUrls: replaceVideoUrls ?? this.replaceVideoUrls,
      scoringEnabled: scoringEnabled ?? this.scoringEnabled,
      skipEnabled: skipEnabled ?? this.skipEnabled,
      skipMs: skipMs ?? this.skipMs,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'disableModuleCheck': disableModuleCheck,
    'disableForegroundCheck': disableForegroundCheck,
    'replaceVideoUrls': replaceVideoUrls,
    'scoringEnabled': scoringEnabled,
    'skipEnabled': skipEnabled,
    'skipMs': skipMs.clamp(0, 30000),
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final rawSkip = json['skipMs'];
    return AppSettings(
      disableModuleCheck: json['disableModuleCheck'] as bool? ?? true,
      disableForegroundCheck: json['disableForegroundCheck'] as bool? ?? true,
      replaceVideoUrls: json['replaceVideoUrls'] as bool? ?? true,
      scoringEnabled: json['scoringEnabled'] as bool? ?? true,
      skipEnabled: json['skipEnabled'] as bool? ?? true,
      skipMs: rawSkip is num ? rawSkip.toInt().clamp(0, 30000) : 150,
    );
  }
}

const List<String> scoringTechniqueNames = <String>[
  'しゃくり',
  '大しゃくり',
  '早いしゃくり',
  '早いしゃくり（強）',
  'L字アクセント',
  'L字アクセント（強）',
  'V字アクセント',
  'V字アクセント（カット）',
  'V字アクセント（下）',
  '逆V字アクセント',
  '先頭こぶし',
  'こぶし',
  'フライダウン',
  'ハンマリング・オン',
  'プリング・オフ',
  '上昇ポルタメント',
  '下降ポルタメント',
  '上昇スロープ',
  'フォール',
  '早いフォール',
  'ヒーカップ',
  'フォール付きヒーカップ',
  'スローダウン',
  'スライダー',
  '水平',
  'スタッカート',
  'U字',
  '逆U字',
  'への字',
  'アーチ',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ジャストヒット',
  'エッジボイス',
  'フォールエッジ',
  '逆こぶし',
  '歌い回しなし',
];

const List<int> canonicalScoringTechniqueIds = <int>[
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  39,
  40,
  41,
  42,
  43,
];

int canonicalScoringTechniqueId(int id) => id >= 30 && id <= 38 ? 30 : id;

String scoringTechniqueName(int id) {
  if (id < 0 || id >= scoringTechniqueNames.length) return '不明';
  return scoringTechniqueNames[id];
}

String scoringTechniqueAsset(int id) {
  final canonical = canonicalScoringTechniqueId(id);
  return 'assets/scoring/technique_${canonical.toString().padLeft(2, '0')}.png';
}

class ScoringEvent {
  const ScoringEvent({
    required this.techniqueId,
    required this.value,
    required this.timestamp,
  });

  final int techniqueId;
  final int value;
  final int timestamp;

  String get name => scoringTechniqueName(techniqueId);
}

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
      artist: _safeText(json['artist'], 300),
      title: _safeText(json['title'], 300),
    );
  }

  static String _safeText(Object? value, int limit) {
    if (value is! String) return '';
    final cleaned = value
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.length <= limit ? cleaned : cleaned.substring(0, limit);
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
      artist: TrackRecord._safeText(json['artist'], 300),
      title: TrackRecord._safeText(json['title'], 300),
    );
  }
}

class PlaybackDescriptor {
  const PlaybackDescriptor({
    required this.videoId,
    required this.highUrl,
    required this.lowUrl,
  });

  final String videoId;
  final Uri? highUrl;
  final Uri? lowUrl;

  List<Uri> get upstreamUrls =>
      <Uri>{?highUrl, ?lowUrl}.toList(growable: false);

  factory PlaybackDescriptor.fromJson(Map<String, dynamic> json) {
    Uri? parseUrl(Object? raw) {
      if (raw is! String || raw.length > 8192) return null;
      final uri = Uri.tryParse(raw);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return null;
      }
      return uri;
    }

    return PlaybackDescriptor(
      videoId: normalizeVideoAssetId(json['videoId']),
      highUrl: parseUrl(json['highUrl']),
      lowUrl: parseUrl(json['lowUrl']),
    );
  }
}

String prettyJson(Object value) =>
    const JsonEncoder.withIndent('  ').convert(value);

enum RemoteSearchMode {
  keyword,
  title,
  artist,
  ranking,
  newReleases,
  favorites,
  history,
}

extension RemoteSearchModeWire on RemoteSearchMode {
  String get wireName => switch (this) {
    RemoteSearchMode.newReleases => 'new',
    _ => name,
  };
}

enum RemoteReservationMode { normal, cutIn, originalKey }

enum RemotePlayType { standard, guideVocal, artistVideo }

class RemoteSongDetail {
  const RemoteSongDetail({
    required this.videoId,
    required this.startLyric,
    required this.originalKey,
    required this.playTypes,
  });

  final String videoId;
  final String startLyric;
  final int originalKey;
  final Set<RemotePlayType> playTypes;

  bool supports(RemotePlayType type) => playTypes.contains(type);

  factory RemoteSongDetail.fromJson(Map<String, dynamic> json) {
    final rawPlayTypes = json['playTypes'];
    final playTypes = <RemotePlayType>{};
    if (rawPlayTypes is List) {
      for (final raw in rawPlayTypes) {
        final name = raw?.toString();
        for (final type in RemotePlayType.values) {
          if (type.name == name) playTypes.add(type);
        }
      }
    }
    final rawKey = json['originalKey'];
    final originalKey = rawKey is num ? rawKey.toInt() : 0;
    return RemoteSongDetail(
      videoId: normalizeVideoAssetId(json['videoId']),
      startLyric: TrackRecord._safeText(json['startLyric'], 300),
      originalKey: originalKey.clamp(-7, 7).toInt(),
      playTypes: Set<RemotePlayType>.unmodifiable(playTypes),
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'videoId': videoId,
    'startLyric': startLyric,
    'originalKey': originalKey,
    'playTypes': playTypes.map((type) => type.name).toList(growable: false),
  };
}

class RemoteReservationOptions {
  const RemoteReservationOptions({
    this.mode = RemoteReservationMode.normal,
    this.key = 0,
    this.scoring = false,
    this.playType = RemotePlayType.standard,
  });

  final RemoteReservationMode mode;
  final int key;
  final bool scoring;
  final RemotePlayType playType;
}

class RemoteSong {
  const RemoteSong({
    required this.token,
    required this.videoId,
    required this.artist,
    required this.title,
    this.kind = 'song',
    this.favorite = false,
    this.history = false,
  });

  final String token;
  final String videoId;
  final String artist;
  final String title;
  final String kind;
  final bool favorite;
  final bool history;

  bool get isArtist => kind == 'artist';
  bool get isDisplayableSearchResult =>
      token.isNotEmpty &&
      (videoId.isNotEmpty || isArtist || favorite || history);

  factory RemoteSong.fromJson(Map<String, dynamic> json) {
    final rawToken = json['token'];
    final token =
        rawToken is String &&
            rawToken.length <= 160 &&
            RegExp(r'^[0-9A-Za-z_-]+$').hasMatch(rawToken)
        ? rawToken
        : '';
    return RemoteSong(
      token: token,
      videoId: normalizeVideoAssetId(json['videoId']),
      artist: TrackRecord._safeText(json['artist'], 300),
      title: TrackRecord._safeText(json['title'], 300),
      kind: json['kind'] == 'artist' ? 'artist' : 'song',
      favorite: json['favorite'] == true,
      history: json['history'] == true,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'token': token,
    'videoId': videoId,
    'artist': artist,
    'title': title,
    'kind': kind,
    'favorite': favorite,
    'history': history,
  };
}

class RemoteReservationResult {
  const RemoteReservationResult({
    required this.accepted,
    required this.message,
    this.videoId = '',
    this.artist = '',
    this.title = '',
  });

  final bool accepted;
  final String message;
  final String videoId;
  final String artist;
  final String title;

  factory RemoteReservationResult.fromJson(Map<String, dynamic> json) {
    return RemoteReservationResult(
      accepted: json['accepted'] == true,
      message: TrackRecord._safeText(json['message'], 500),
      videoId: normalizeVideoAssetId(json['videoId']),
      artist: TrackRecord._safeText(json['artist'], 300),
      title: TrackRecord._safeText(json['title'], 300),
    );
  }
}

class RemoteFavoriteResult {
  const RemoteFavoriteResult({
    required this.accepted,
    required this.favorite,
    required this.message,
  });

  final bool accepted;
  final bool favorite;
  final String message;

  factory RemoteFavoriteResult.fromJson(Map<String, dynamic> json) {
    return RemoteFavoriteResult(
      accepted: json['accepted'] == true,
      favorite: json['favorite'] == true,
      message: TrackRecord._safeText(json['message'], 500),
    );
  }
}

class RemoteControlState {
  const RemoteControlState({
    required this.connected,
    required this.playing,
    required this.paused,
    required this.key,
    this.damScoring = false,
    this.videoId = '',
    this.artist = '',
    this.title = '',
  });

  final bool connected;
  final bool playing;
  final bool paused;
  final int key;
  final bool damScoring;
  final String videoId;
  final String artist;
  final String title;

  factory RemoteControlState.fromJson(Map<String, dynamic> json) {
    final rawKey = json['key'];
    return RemoteControlState(
      connected: json['connected'] == true,
      playing: json['playing'] == true,
      paused: json['paused'] == true,
      key: rawKey is num ? rawKey.toInt().clamp(-7, 7) : 0,
      damScoring: json['damScoring'] == true,
      videoId: normalizeVideoAssetId(json['videoId']),
      artist: TrackRecord._safeText(json['artist'], 300),
      title: TrackRecord._safeText(json['title'], 300),
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'connected': connected,
    'playing': playing,
    'paused': paused,
    'key': key,
    'damScoring': damScoring,
    'videoId': videoId,
    'artist': artist,
    'title': title,
  };
}

class RemoteQueueEntry {
  const RemoteQueueEntry({
    required this.token,
    required this.queueId,
    required this.index,
    required this.cutIn,
    required this.artist,
    required this.title,
  });

  final String token;
  final int queueId;
  final int index;
  final bool cutIn;
  final String artist;
  final String title;

  factory RemoteQueueEntry.fromJson(Map<String, dynamic> json) {
    final rawToken = json['token'];
    final rawQueueId = json['queueId'];
    final rawIndex = json['index'];
    return RemoteQueueEntry(
      token:
          rawToken is String &&
              rawToken.length <= 80 &&
              RegExp(r'^q_[cn]_[0-9]+$').hasMatch(rawToken)
          ? rawToken
          : '',
      queueId: rawQueueId is num ? rawQueueId.toInt() : 0,
      index: rawIndex is num ? rawIndex.toInt() : 0,
      cutIn: json['cutIn'] == true,
      artist: TrackRecord._safeText(json['artist'], 300),
      title: TrackRecord._safeText(json['title'], 300),
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'token': token,
    'queueId': queueId,
    'index': index,
    'cutIn': cutIn,
    'artist': artist,
    'title': title,
  };
}
