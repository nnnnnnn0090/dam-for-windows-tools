// Project: DAM for Windows Tools
// File: remote_reservation.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'remote_song.dart';
import 'value_objects.dart';

/// 通常予約・割り込み・原曲キー予約の、DAMへ送る予約方法を表します。
enum RemoteReservationMode { normal, cutIn, originalKey }

/// 曲詳細画面で利用者が指定した、1回分の予約条件を表します。
class RemoteReservationOptions {
  /// 指定がない項目をDAM標準の通常予約として予約条件を生成します。
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

/// DAMが予約要求を受理したかと、確定した曲情報を表します。
class RemoteReservationResult {
  /// 予約処理の成否と利用者へ表示する結果メッセージを生成します。
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

  /// Sidecarの予約応答を、表示可能な長さと公開動画IDへ正規化します。
  factory RemoteReservationResult.fromJson(Map<String, dynamic> json) =>
      RemoteReservationResult(
        accepted: json['accepted'] == true,
        message: sanitizeText(json['message'], maximumLength: 500),
        videoId: normalizeVideoAssetId(json['videoId']),
        artist: sanitizeText(json['artist'], maximumLength: 300),
        title: sanitizeText(json['title'], maximumLength: 300),
      );
}

/// お気に入り登録または解除の実行結果を表します。
class RemoteFavoriteResult {
  /// 要求の成否、変更後の状態、利用者向けメッセージを生成します。
  const RemoteFavoriteResult({
    required this.accepted,
    required this.favorite,
    required this.message,
  });

  final bool accepted;
  final bool favorite;
  final String message;

  /// Sidecar応答からお気に入りの確定状態を安全に復元します。
  factory RemoteFavoriteResult.fromJson(Map<String, dynamic> json) =>
      RemoteFavoriteResult(
        accepted: json['accepted'] == true,
        favorite: json['favorite'] == true,
        message: sanitizeText(json['message'], maximumLength: 500),
      );
}
