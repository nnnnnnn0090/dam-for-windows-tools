// Project: DAM for Windows Tools
// File: remote_request_broker_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:dam_for_windows_tools/infrastructure/sidecar/remote_request_broker.dart';
import 'package:flutter_test/flutter_test.dart';

/// 相関ID、操作トークン検証、ヘルパー終了時の待機解放を検証します。
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

  test(
    'shares one sidecar command between concurrent state requests',
    () async {
      final commands = <Map<String, dynamic>>[];
      final broker = RemoteRequestBroker(
        send: commands.add,
        isRunning: () => true,
      );

      final first = broker.remoteState();
      final second = broker.remoteState();
      expect(identical(first, second), isTrue);
      expect(commands, hasLength(1));

      final firstRequestId = commands.single['requestId'];
      broker.handleEvent(<String, dynamic>{
        'type': 'remote-state-result',
        'requestId': firstRequestId,
        'result': <String, Object>{
          'connected': true,
          'playing': false,
          'paused': false,
          'key': 0,
        },
      });
      expect((await first).connected, isTrue);
      expect((await second).connected, isTrue);

      final next = broker.remoteState();
      expect(commands, hasLength(2));
      broker.handleEvent(<String, dynamic>{
        'type': 'remote-state-result',
        'requestId': commands.last['requestId'],
        'result': <String, Object>{
          'connected': true,
          'playing': true,
          'paused': false,
          'key': 0,
        },
      });
      expect((await next).playing, isTrue);
    },
  );

  test(
    'allows a yes/no response only through the confirmed action names',
    () async {
      Map<String, dynamic>? command;
      final broker = RemoteRequestBroker(
        send: (value) => command = value,
        isRunning: () => true,
      );

      final future = broker.remoteControl('confirmYes');
      expect(command!['type'], 'remoteControl');
      expect(command!['action'], 'confirmYes');
      expect(
        broker.handleEvent(<String, dynamic>{
          'type': 'remote-control-result',
          'requestId': command!['requestId'],
          'result': <String, Object>{
            'connected': true,
            'playing': false,
            'paused': false,
            'key': 0,
          },
        }),
        isTrue,
      );

      expect((await future).connected, isTrue);
      await expectLater(
        broker.remoteControl('confirmMaybe'),
        throwsFormatException,
      );
    },
  );
}
