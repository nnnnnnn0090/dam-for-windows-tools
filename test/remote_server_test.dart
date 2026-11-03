import 'dart:convert';
import 'dart:io';

import 'package:dam_for_windows_tools/domain/remote.dart';
import 'package:dam_for_windows_tools/infra/helper/dam_link.dart';
import 'package:dam_for_windows_tools/infra/remote/remote_server.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBackend implements RemoteBackend {
  final calls = <String>[];

  @override
  Future<List<RemoteSong>> search(String query, RemoteSearchMode mode) async {
    calls.add('search:${mode.wireName}:$query');
    if (query == 'busy') {
      throw const RemoteFailure(
        RemoteFailureKind.busy,
        'another remote request is running',
      );
    }
    return <RemoteSong>[
      RemoteSong(token: 't1', videoId: '1-1', artist: 'A', title: query),
    ];
  }

  @override
  Future<RemoteSongDetail> detail(String token) async => const RemoteSongDetail(
    videoId: '1-1',
    startLyric: 'la',
    originalKey: 0,
    playTypes: <RemotePlayType>[RemotePlayType.standard],
  );

  @override
  Future<RemoteReservationResult> reserve(
    String token,
    RemoteReservationOptions options,
  ) async {
    calls.add(
      'reserve:${options.mode.name}:${options.key}:${options.playType.name}:${options.scoring}',
    );
    return const RemoteReservationResult(accepted: true, message: '予約しました');
  }

  @override
  Future<RemoteFavoriteResult> favorite(
    String token, {
    required bool add,
  }) async => RemoteFavoriteResult(accepted: true, favorite: add, message: '');

  @override
  Future<RemoteControlState> controlState() async => const RemoteControlState(
    connected: true,
    playing: false,
    paused: false,
    key: 0,
  );

  @override
  Future<RemoteControlState> control(RemoteControlAction action) async {
    calls.add('control:${action.name}');
    return controlState();
  }

  @override
  Future<List<RemoteQueueEntry>> queue() async => const <RemoteQueueEntry>[];

  @override
  Future<List<RemoteQueueEntry>> queueAction(
    RemoteQueueAction action,
    String token,
  ) async {
    calls.add('queue:${action.name}:$token');
    return const <RemoteQueueEntry>[];
  }
}

void main() {
  late RemoteServer server;
  late FakeBackend backend;
  final client = HttpClient();

  setUp(() async {
    backend = FakeBackend();
    server = RemoteServer(
      port: 18766,
      backend: backend,
      loadPage: () async => '<html>remote</html>',
      onLog: (_) {},
    );
    await server.start();
  });

  tearDown(() => server.stop());

  Future<(int, Map<String, Object?>)> api(
    String endpoint,
    Object body, {
    String? origin,
    String contentType = 'application/json',
    String? host,
  }) async {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:18766/${server.token}/api/$endpoint'),
    );
    request.headers.set(HttpHeaders.contentTypeHeader, contentType);
    if (origin != null) request.headers.set('origin', origin);
    if (host != null) request.headers.host = host;
    request.write(body is String ? body : jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    return (
      response.statusCode,
      (jsonDecode(text) as Map).cast<String, Object?>(),
    );
  }

  test('トークン付きURLでだけ画面を返し、セキュリティヘッダーを付ける', () async {
    final ok = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:18766/${server.token}/'),
    )).close();
    expect(ok.statusCode, 200);
    expect(ok.headers.value('x-frame-options'), 'DENY');
    expect(await utf8.decodeStream(ok), contains('remote'));
    final ng = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:18766/wrong/'),
    )).close();
    expect(ng.statusCode, 404);
    await ng.drain<void>();
  });

  test('検索・履歴・予約・操作の各APIを中継する', () async {
    final (status, body) = await api('search', {'query': 'abc', 'mode': 'new'});
    expect(status, 200);
    expect((body['songs']! as List).single, containsPair('title', 'abc'));
    expect((await api('history', <String, Object>{})).$1, 200);
    final reserve = await api('reserve', {
      'token': 't1',
      'mode': 'cutIn',
      'key': -3,
      'scoring': true,
      'playType': 'guideVocal',
    });
    expect(reserve.$2['accepted'], isTrue);
    expect((await api('control', {'action': 'keyUp'})).$1, 200);
    expect(
      (await api('queue-action', {'action': 'moveUp', 'token': 'q_n_2'})).$1,
      200,
    );
    expect(backend.calls, <String>[
      'search:new:abc',
      'search:history:',
      'reserve:cutIn:-3:guideVocal:true',
      'control:keyUp',
      'queue:moveUp:q_n_2',
    ]);
  });

  test('入力検証', () async {
    expect((await api('search', {'query': 'a', 'mode': 'history'})).$1, 400);
    expect((await api('reserve', {'token': 't1', 'key': 8})).$1, 400);
    expect((await api('reserve', {'token': 't1', 'key': 1.5})).$1, 400);
    expect((await api('detail', {'token': '../x'})).$1, 400);
    expect((await api('control', {'action': 'explode'})).$1, 400);
    expect(
      (await api('queue-action', {'action': 'remove', 'token': 'x'})).$1,
      400,
    );
    expect((await api('unknown', <String, Object>{})).$1, 404);
  });

  test('別オリジン・非JSON・巨大本文・不明なHostを拒否する', () async {
    expect((await api('state', {}, origin: 'http://evil.example')).$1, 403);
    expect((await api('state', {}, origin: 'http://127.0.0.1:18766')).$1, 200);
    expect((await api('state', '{}', contentType: 'text/plain')).$1, 415);
    expect((await api('search', {'query': 'x' * 5000})).$1, 413);
    expect((await api('state', {}, host: 'evil.example')).$1, 421);
  });

  test('DAMの処理中は409を返す', () async {
    final (status, body) = await api('search', {'query': 'busy'});
    expect(status, 409);
    expect(body['error'], contains('処理中'));
  });

  test('応答を受け取らない端末が同時処理数を埋めても、期限で接続を切って回復する', () async {
    final logs = <String>[];
    final stalled = RemoteServer(
      port: 18769,
      backend: FakeBackend(),
      // 受信側の窓が埋まるよう、大きなページを返します。
      loadPage: () async => '<html>${'x' * (4 * 1024 * 1024)}</html>',
      onLog: logs.add,
      requestDeadline: const Duration(seconds: 2),
    );
    await stalled.start();
    final sockets = <Socket>[];
    Future<int> probe() async {
      final response = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:18769/wrong/'),
      )).close();
      await response.drain<void>();
      return response.statusCode;
    }

    try {
      for (var i = 0; i < RemoteServer.maximumConcurrentRequests; i++) {
        // ページを要求したまま、応答を一切読まない端末
        final socket = await Socket.connect('127.0.0.1', 18769);
        socket.write(
          'GET /${stalled.token}/ HTTP/1.1\r\nHost: 127.0.0.1:18769\r\n\r\n',
        );
        await socket.flush();
        sockets.add(socket);
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await probe(), 503);
      expect(logs, contains(contains('同時要求が上限')));

      await Future<void>.delayed(const Duration(seconds: 3));
      expect(await probe(), 404, reason: '期限を過ぎた要求が枠を返していない');
      expect(logs, contains(allOf(contains('接続を切りました'), contains('ページの送信'))));
      // 処理中の要求の記録には、URLのトークンを含めない
      final traces = logs.where(
        (l) => l.contains('同時要求') || l.contains('接続を切りました'),
      );
      expect(traces, isNotEmpty);
      expect(traces.where((l) => l.contains(stalled.token)), isEmpty);
    } finally {
      for (final socket in sockets) {
        socket.destroy();
      }
      await stalled.stop();
    }
  });

  test('プライベートアドレス判定', () {
    expect(
      RemoteServer.isPrivateAddress(InternetAddress('192.168.1.2')),
      isTrue,
    );
    expect(
      RemoteServer.isPrivateAddress(InternetAddress('172.20.0.1')),
      isTrue,
    );
    expect(
      RemoteServer.isPrivateAddress(InternetAddress('172.32.0.1')),
      isFalse,
    );
    expect(RemoteServer.isPrivateAddress(InternetAddress('8.8.8.8')), isFalse);
    expect(RemoteServer.isPrivateAddress(InternetAddress('::1')), isTrue);
    expect(RemoteServer.isPrivateAddress(InternetAddress('fe80::1')), isFalse);
  });
}
