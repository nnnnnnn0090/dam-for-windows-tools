// Project: DAM for Windows Tools
// File: remote_control.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'value_objects.dart';

/// Webリモコンへ公開する、DAMの接続状態と現在の演奏状態を表します。
///
/// DAM内部の値を直接公開せず、表示と操作判断に必要な最小項目だけを保持します。
class RemoteControlState {
  /// 接続・再生・キー・曲情報をまとめたリモコン状態を生成します。
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

  /// Sidecar応答を検証し、キー範囲と表示文字列を正規化して復元します。
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

  /// ブラウザへ返してよい項目だけをJSON形式へ変換します。
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

/// DAMの予約一覧にある1曲を、並べ替え操作用の識別子とともに表します。
class RemoteQueueEntry {
  /// 予約順、割り込み状態、画面表示用の曲情報をまとめて生成します。
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

  /// Sidecar応答から予約行を復元し、操作トークンの形式を厳密に検証します。
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

  /// Webリモコンの予約一覧へ返す形式に変換します。
  Map<String, Object> toJson() => <String, Object>{
    'token': token,
    'queueId': queueId,
    'index': index,
    'cutIn': cutIn,
    'artist': artist,
    'title': title,
  };
}
