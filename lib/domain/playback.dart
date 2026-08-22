// Project: DAM for Windows Tools
// File: playback.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'value_objects.dart';

/// DAMが再生しようとしている動画と、利用可能な上流配信URLを表します。
///
/// 動画IDは公開形式だけを保持し、上流URLはローカル配信のhigh→low退避に
/// 使用します。
class PlaybackDescriptor {
  /// 検証済みの動画IDと、利用できる品質別URLから再生情報を生成します。
  const PlaybackDescriptor({
    required this.videoId,
    required this.highUrl,
    required this.lowUrl,
  });

  final String videoId;
  final Uri? highUrl;
  final Uri? lowUrl;

  /// highを優先しつつ、同一URLを重複させない上流候補一覧を返します。
  List<Uri> get upstreamUrls =>
      <Uri>{?highUrl, ?lowUrl}.toList(growable: false);

  /// Sidecarの通知を検証し、HTTP(S)以外のURLを除外して復元します。
  factory PlaybackDescriptor.fromJson(Map<String, dynamic> json) {
    return PlaybackDescriptor(
      videoId: normalizeVideoAssetId(json['videoId']),
      highUrl: parseHttpUri(json['highUrl']),
      lowUrl: parseHttpUri(json['lowUrl']),
    );
  }
}
