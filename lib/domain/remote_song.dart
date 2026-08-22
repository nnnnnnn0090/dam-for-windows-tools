// Project: DAM for Windows Tools
// File: remote_song.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'value_objects.dart';

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
    final playTypes = <RemotePlayType>{};
    final rawPlayTypes = json['playTypes'];
    if (rawPlayTypes is List) {
      for (final raw in rawPlayTypes) {
        for (final type in RemotePlayType.values) {
          if (type.name == raw?.toString()) playTypes.add(type);
        }
      }
    }
    final rawKey = json['originalKey'];
    return RemoteSongDetail(
      videoId: normalizeVideoAssetId(json['videoId']),
      startLyric: sanitizeText(json['startLyric'], maximumLength: 300),
      originalKey: (rawKey is num ? rawKey.toInt() : 0).clamp(-7, 7),
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
      artist: sanitizeText(json['artist'], maximumLength: 300),
      title: sanitizeText(json['title'], maximumLength: 300),
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
