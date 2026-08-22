// Project: DAM for Windows Tools
// File: playback.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'value_objects.dart';

class PlaybackDescriptor {
  const PlaybackDescriptor({
    required this.videoId,
    required this.highUrl,
    required this.lowUrl,
  });

  final String videoId;
  final Uri? highUrl;
  final Uri? lowUrl;

  List<Uri> get upstreamUrls =>
      <Uri>{?highUrl, ?lowUrl}.toList(growable: false);

  factory PlaybackDescriptor.fromJson(Map<String, dynamic> json) {
    return PlaybackDescriptor(
      videoId: normalizeVideoAssetId(json['videoId']),
      highUrl: parseHttpUri(json['highUrl']),
      lowUrl: parseHttpUri(json['lowUrl']),
    );
  }
}
