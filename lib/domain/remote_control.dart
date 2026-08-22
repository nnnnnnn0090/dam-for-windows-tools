// Project: DAM for Windows Tools
// File: remote_control.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'value_objects.dart';

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
      artist: sanitizeText(json['artist'], maximumLength: 300),
      title: sanitizeText(json['title'], maximumLength: 300),
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
      artist: sanitizeText(json['artist'], maximumLength: 300),
      title: sanitizeText(json['title'], maximumLength: 300),
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
