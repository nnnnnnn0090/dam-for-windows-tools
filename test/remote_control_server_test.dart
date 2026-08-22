// Project: DAM for Windows Tools
// File: remote_control_server_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:convert';
import 'dart:io';

import 'package:dam_for_windows_tools/domain/models.dart';
import 'package:dam_for_windows_tools/infrastructure/remote_control_server.dart';
import 'package:dam_for_windows_tools/infrastructure/remote_page_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'remote server requires its token and rejects unsafe requests',
    () async {
      const sessionToken =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final server = RemoteControlServer(
        port: 0,
        bindAddress: InternetAddress.loopbackIPv4,
        advertisedAddress: '127.0.0.1',
        sessionToken: sessionToken,
        pageProvider: _StaticRemotePageProvider(),
        search: (_, _) async => <RemoteSong>[],
        readSongDetail: (_) async => const RemoteSongDetail(
          videoId: '6184-92',
          startLyric: '',
          originalKey: 0,
          playTypes: <RemotePlayType>{RemotePlayType.standard},
        ),
        reserve: (_, _) async =>
            const RemoteReservationResult(accepted: true, message: ''),
        favorite: (_, enabled) async => RemoteFavoriteResult(
          accepted: true,
          favorite: enabled,
          message: '',
        ),
        readState: () async => disconnectedState,
        controlPlayback: (_) async => disconnectedState,
        readQueue: () async => <RemoteQueueEntry>[],
        controlQueue: (_, _) async => <RemoteQueueEntry>[],
        readHistory: () async => const <RemoteSong>[
          RemoteSong(
            token: 'history_0',
            videoId: '',
            artist: '履歴歌手',
            title: '履歴曲',
            history: true,
          ),
        ],
        onLog: (_) {},
      );
      final client = HttpClient();
      try {
        await server.start();
        final base = Uri.parse(server.url!);

        final page = await (await client.getUrl(base)).close();
        expect(page.statusCode, HttpStatus.ok);
        expect(page.headers.value('X-Frame-Options'), 'DENY');
        await page.drain<void>();

        final wrongToken = base.replace(path: '/wrong/');
        final missing = await (await client.getUrl(wrongToken)).close();
        expect(missing.statusCode, HttpStatus.notFound);
        await missing.drain<void>();

        final foreignOrigin = await client.postUrl(base.resolve('api/state'));
        foreignOrigin.headers
          ..contentType = ContentType.json
          ..set('Origin', 'http://example.invalid');
        foreignOrigin.write('{}');
        final forbidden = await foreignOrigin.close();
        expect(forbidden.statusCode, HttpStatus.forbidden);
        await forbidden.drain<void>();

        final oversized = await client.postUrl(base.resolve('api/state'));
        oversized.headers.contentType = ContentType.json;
        oversized.write(jsonEncode(<String, String>{'value': 'x' * 5000}));
        final tooLarge = await oversized.close();
        expect(tooLarge.statusCode, HttpStatus.requestEntityTooLarge);
        await tooLarge.drain<void>();

        final historyRequest = await client.postUrl(
          base.resolve('api/history'),
        );
        historyRequest.headers.contentType = ContentType.json;
        historyRequest.write('{}');
        final historyResponse = await historyRequest.close();
        expect(historyResponse.statusCode, HttpStatus.ok);
        final historyJson = jsonDecode(
          await utf8.decoder.bind(historyResponse).join(),
        ) as Map<String, dynamic>;
        final historyRows = historyJson['rows'] as List<dynamic>;
        expect(historyRows, hasLength(1));
        expect((historyRows.single as Map<String, dynamic>)['history'], isTrue);
      } finally {
        client.close(force: true);
        await server.stop();
      }
    },
  );
}

class _StaticRemotePageProvider extends RemotePageProvider {
  @override
  Future<String> load() async => '<!doctype html><title>Remote</title>';
}

const disconnectedState = RemoteControlState(
  connected: false,
  playing: false,
  paused: false,
  key: 0,
);
