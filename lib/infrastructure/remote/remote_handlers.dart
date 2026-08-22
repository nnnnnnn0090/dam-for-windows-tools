// Project: DAM for Windows Tools
// File: remote/remote_handlers.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import '../../domain/remote.dart';

typedef RemoteSongSearch = Future<List<RemoteSong>> Function(
  String query,
  RemoteSearchMode mode,
);
typedef RemoteSongReservation = Future<RemoteReservationResult> Function(
  String token,
  RemoteReservationOptions options,
);
typedef RemoteSongDetailReader = Future<RemoteSongDetail> Function(
  String token,
);
typedef RemoteFavoriteCommand = Future<RemoteFavoriteResult> Function(
  String token,
  bool favorite,
);
typedef RemoteStateReader = Future<RemoteControlState> Function();
typedef RemotePlaybackCommand = Future<RemoteControlState> Function(
  String action,
);
typedef RemoteQueueReader = Future<List<RemoteQueueEntry>> Function();
typedef RemoteQueueCommand = Future<List<RemoteQueueEntry>> Function(
  String action,
  String token,
);
typedef RemoteHistoryReader = Future<List<RemoteSong>> Function();

class RemoteHandlers {
  const RemoteHandlers({
    required this.search,
    required this.readSongDetail,
    required this.reserve,
    required this.favorite,
    required this.readState,
    required this.controlPlayback,
    required this.readQueue,
    required this.controlQueue,
    required this.readHistory,
  });

  final RemoteSongSearch search;
  final RemoteSongDetailReader readSongDetail;
  final RemoteSongReservation reserve;
  final RemoteFavoriteCommand favorite;
  final RemoteStateReader readState;
  final RemotePlaybackCommand controlPlayback;
  final RemoteQueueReader readQueue;
  final RemoteQueueCommand controlQueue;
  final RemoteHistoryReader readHistory;
}
