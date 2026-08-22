// Project: DAM for Windows Tools
// File: tracks.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'value_objects.dart';

/// 永続化を許可した、再生履歴1件分の最小情報を表します。
///
/// 権利とプライバシーに配慮し、URL・動画・時刻・ファイルパスは保持しません。
class TrackRecord {
  /// 公開動画ID、アーティスト名、曲名だけから履歴を生成します。
  const TrackRecord({
    required this.videoId,
    required this.artist,
    required this.title,
  });

  final String videoId;
  final String artist;
  final String title;

  /// 同じ動画IDの履歴へ、後から到着した正確な曲情報を反映します。
  TrackRecord copyWith({String? artist, String? title}) => TrackRecord(
    videoId: videoId,
    artist: artist ?? this.artist,
    title: title ?? this.title,
  );

  /// 永続化を許可した3項目だけをJSON形式へ変換します。
  Map<String, String> toJson() => <String, String>{
    'videoId': videoId,
    'artist': artist,
    'title': title,
  };

  /// 保存済みJSONを検証し、制御文字や不正な動画IDを除去して復元します。
  factory TrackRecord.fromJson(Map<String, dynamic> json) {
    return TrackRecord(
      videoId: normalizeVideoAssetId(json['videoId']),
      artist: sanitizeText(json['artist'], maximumLength: 300),
      title: sanitizeText(json['title'], maximumLength: 300),
    );
  }
}

/// 1回の再生ジョブがローカル配信のどこまで進んだかを表します。
enum PlaybackStage {
  detected('検知'),
  registered('登録'),
  rewritten('URL置換'),
  preparing('HLS準備'),
  manifestRequested('マニフェスト要求'),
  streaming('配信中'),
  officialFallback('公式退避'),
  failed('失敗');

  /// GUIに表示する固定ラベルを持つ再生段階を定義します。
  const PlaybackStage(this.label);
  final String label;
}

/// 永続履歴と、現在セッションだけの再生状態を組み合わせたGUI表示行です。
class TrackView {
  /// 履歴情報へ必要に応じて一時的な再生状態を付けて生成します。
  const TrackView({required this.record, this.stage});

  final TrackRecord record;
  final PlaybackStage? stage;

  /// 曲情報または再生状態だけを更新した新しい表示行を返します。
  TrackView copyWith({TrackRecord? record, PlaybackStage? stage}) =>
      TrackView(record: record ?? this.record, stage: stage ?? this.stage);
}

/// DAMの曲情報応答から収集した、IDと曲名を結び付ける候補を表します。
class MetadataCandidate {
  /// 同一曲を示す複数IDと、完全一致時に反映する曲情報を生成します。
  const MetadataCandidate({
    required this.ids,
    required this.artist,
    required this.title,
  });

  final List<String> ids;
  final String artist;
  final String title;

  /// Sidecar応答を検証し、不正なIDを候補から除外して復元します。
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
