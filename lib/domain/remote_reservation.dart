// Project: DAM for Windows Tools
// File: remote_reservation.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'remote_song.dart';
import 'value_objects.dart';

enum RemoteReservationMode { normal, cutIn, originalKey }

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

  factory RemoteReservationResult.fromJson(Map<String, dynamic> json) =>
      RemoteReservationResult(
        accepted: json['accepted'] == true,
        message: sanitizeText(json['message'], maximumLength: 500),
        videoId: normalizeVideoAssetId(json['videoId']),
        artist: sanitizeText(json['artist'], maximumLength: 300),
        title: sanitizeText(json['title'], maximumLength: 300),
      );
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

  factory RemoteFavoriteResult.fromJson(Map<String, dynamic> json) =>
      RemoteFavoriteResult(
        accepted: json['accepted'] == true,
        favorite: json['favorite'] == true,
        message: sanitizeText(json['message'], maximumLength: 500),
      );
}
