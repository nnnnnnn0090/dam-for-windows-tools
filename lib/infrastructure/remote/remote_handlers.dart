// Project: DAM for Windows Tools
// File: remote/remote_handlers.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import '../../domain/remote.dart';

/// 検索語と検索種別から曲・歌手候補を取得する関数型です。
typedef RemoteSongSearch = Future<List<RemoteSong>> Function(
  String query,
  RemoteSearchMode mode,
);

/// トークンと予約条件をDAMの予約へ変換する関数型です。
typedef RemoteSongReservation = Future<RemoteReservationResult> Function(
  String token,
  RemoteReservationOptions options,
);

/// 検索結果トークンから曲詳細を取得する関数型です。
typedef RemoteSongDetailReader = Future<RemoteSongDetail> Function(
  String token,
);

/// 指定曲のお気に入り状態を更新する関数型です。
typedef RemoteFavoriteCommand = Future<RemoteFavoriteResult> Function(
  String token,
  bool favorite,
);

/// DAMの現在演奏状態を取得する関数型です。
typedef RemoteStateReader = Future<RemoteControlState> Function();

/// DAMへ演奏操作を送り、更新後状態を取得する関数型です。
typedef RemotePlaybackCommand = Future<RemoteControlState> Function(
  String action,
);

/// DAMの予約一覧を取得する関数型です。
typedef RemoteQueueReader = Future<List<RemoteQueueEntry>> Function();

/// DAMの予約行を操作し、更新後一覧を取得する関数型です。
typedef RemoteQueueCommand = Future<List<RemoteQueueEntry>> Function(
  String action,
  String token,
);

/// DAM本体の再生履歴を取得する関数型です。
typedef RemoteHistoryReader = Future<List<RemoteSong>> Function();

/// HTTP層から呼べる操作だけを束ねる、依存性注入用の関数集合です。
class RemoteHandlers {
  /// 検索・予約・演奏・履歴の各操作実装を明示的に受け取ります。
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
