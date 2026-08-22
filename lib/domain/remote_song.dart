// Project: DAM for Windows Tools
// File: remote_song.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'value_objects.dart';

/// Webリモコンで選択できる検索元を表します。
enum RemoteSearchMode {
  keyword,
  title,
  artist,
  ranking,
  newReleases,
  favorites,
  history,
}

/// Dart上の列挙値をSidecarプロトコルの検索モード名へ変換します。
extension RemoteSearchModeWire on RemoteSearchMode {
  /// `newReleases`だけは既存プロトコルに合わせて`new`として送信します。
  String get wireName => switch (this) {
    RemoteSearchMode.newReleases => 'new',
    _ => name,
  };
}

/// 曲ごとに選択できるDAMの演奏素材を表します。
enum RemotePlayType { standard, guideVocal, artistVideo }

/// 曲詳細APIから得た、予約条件の選択に必要な付加情報を表します。
class RemoteSongDetail {
  /// 動画ID、歌いだし、原曲キー、対応演奏タイプをまとめて生成します。
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

  /// 指定した演奏タイプをこの曲で予約できるか判定します。
  bool supports(RemotePlayType type) => playTypes.contains(type);

  /// Sidecar応答を検証し、未知の演奏タイプを除外して曲詳細を復元します。
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

  /// Webリモコンの曲詳細画面へ返す形式に変換します。
  Map<String, Object> toJson() => <String, Object>{
    'videoId': videoId,
    'startLyric': startLyric,
    'originalKey': originalKey,
    'playTypes': playTypes.map((type) => type.name).toList(growable: false),
  };
}

/// 検索結果・お気に入り・履歴に共通して表示する曲または歌手を表します。
class RemoteSong {
  /// Sidecar操作用トークンと、利用者に見せる曲情報をまとめて生成します。
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

  /// この行が曲ではなく歌手一覧への導線かどうかを返します。
  bool get isArtist => kind == 'artist';

  /// 安全な操作トークンと表示先を持ち、検索結果として利用できるか判定します。
  bool get isDisplayableSearchResult =>
      token.isNotEmpty &&
      (videoId.isNotEmpty || isArtist || favorite || history);

  /// Sidecar応答から、許可した文字だけの操作トークンと正規化済み表示値を復元します。
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

  /// ブラウザへ公開する曲情報をJSON形式へ変換します。
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
