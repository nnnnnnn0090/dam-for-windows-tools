// Project: DAM for Windows Tools
// File: remote_request_broker_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:dam_for_windows_tools/infrastructure/sidecar/remote_request_broker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('correlates an out-of-process search response by request ID', () async {
    Map<String, dynamic>? command;
    final broker = RemoteRequestBroker(
      send: (value) => command = value,
      isRunning: () => true,
    );

    final future = broker.searchSongs('Lemon');
    final requestId = command!['requestId'] as String;
    expect(command!['type'], 'remoteSearch');
    expect(
      broker.handleEvent(<String, dynamic>{
        'type': 'remote-search-result',
        'requestId': requestId,
        'rows': <Map<String, Object>>[
          <String, Object>{
            'token': 'result_1',
            'videoId': '3246-51',
            'artist': '米津玄師',
            'title': 'Lemon',
          },
        ],
      }),
      isTrue,
    );

    final songs = await future;
    expect(songs, hasLength(1));
    expect(songs.single.videoId, '3246-51');
  });

  test('rejects malformed tokens before sending a command', () {
    var sent = false;
    final broker = RemoteRequestBroker(
      send: (_) => sent = true,
      isRunning: () => true,
    );
    expect(() => broker.songDetail('../bad'), throwsFormatException);
    expect(sent, isFalse);
  });

  test('fails pending requests when the helper exits', () async {
    final broker = RemoteRequestBroker(send: (_) {}, isRunning: () => true);
    final future = broker.remoteState();
    broker.failAll(StateError('helper exited'));
    await expectLater(future, throwsStateError);
  });
}
