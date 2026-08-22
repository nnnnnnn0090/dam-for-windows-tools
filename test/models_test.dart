// Project: DAM for Windows Tools
// File: models_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'package:dam_for_windows_tools/domain/app_settings.dart';
import 'package:dam_for_windows_tools/domain/playback.dart';
import 'package:dam_for_windows_tools/domain/remote_song.dart';
import 'package:dam_for_windows_tools/domain/tracks.dart';
import 'package:dam_for_windows_tools/domain/value_objects.dart';
import 'package:flutter_test/flutter_test.dart';

/// 公開ID、設定範囲、履歴最小化、URL制限などドメイン境界を検証します。
void main() {
  test('video IDs use only the public hyphenated form', () {
    expect(normalizeVideoAssetId('6184-92'), '6184-92');
    expect(normalizeVideoAssetId(' 6184-92 '), '6184-92');
    expect(normalizeVideoAssetId('5785365'), isEmpty);
    expect(normalizeVideoAssetId('../6184-92'), isEmpty);
    expect(normalizeVideoAssetId('x' * 129), isEmpty);
  });

  test('skip settings clamp unsafe persisted values', () {
    expect(
      const AppSettings(skipEnabled: false, skipMs: 150).effectiveSkipMs,
      0,
    );
    expect(AppSettings.fromJson(<String, dynamic>{'skipMs': -1}).skipMs, 0);
    expect(
      AppSettings.fromJson(<String, dynamic>{'skipMs': 30001}).skipMs,
      30000,
    );
    expect(const AppSettings(skipMs: 30000).effectiveSkipMs, 30000);
  });

  test('history persists only ID, artist and title', () {
    final record = TrackRecord.fromJson(<String, dynamic>{
      'videoId': '6184-92',
      'artist': ' Artist\u0000 Name ',
      'title': 'Title',
      'upstreamUrl': 'https://example.invalid/private',
      'path': r'C:\private.mp4',
    });
    expect(record.toJson(), <String, String>{
      'videoId': '6184-92',
      'artist': 'Artist Name',
      'title': 'Title',
    });
  });

  test(
    'DAM history rows remain selectable before detail resolves the public ID',
    () {
      final song = RemoteSong.fromJson(const <String, Object>{
        'token': 'history_0',
        'videoId': '',
        'artist': '履歴歌手',
        'title': '履歴曲',
        'history': true,
      });

      expect(song.history, isTrue);
      expect(song.videoId, isEmpty);
      expect(song.isDisplayableSearchResult, isTrue);
    },
  );

  test('playback descriptors accept only bounded HTTP URLs', () {
    final descriptor = PlaybackDescriptor.fromJson(<String, dynamic>{
      'videoId': '6184-92',
      'highUrl': 'https://example.invalid/index.m3u8',
      'lowUrl': 'file:///private/index.m3u8',
    });
    expect(descriptor.highUrl?.scheme, 'https');
    expect(descriptor.lowUrl, isNull);
    expect(
      PlaybackDescriptor.fromJson(<String, dynamic>{
        'videoId': '6184-92',
        'highUrl': 'https://example.invalid/${'x' * 8192}',
      }).highUrl,
      isNull,
    );
  });
}
