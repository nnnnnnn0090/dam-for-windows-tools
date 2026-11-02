import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dam_for_windows_tools/domain/remote.dart';
import 'package:dam_for_windows_tools/infra/helper/dam_link.dart';
import 'package:dam_for_windows_tools/infra/helper/helper_process.dart';
import 'package:dam_for_windows_tools/infra/helper/json_lines.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// flutter_tester.exe の位置から、同じSDKの dart.exe を求めます。
String dartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  while (p.basename(directory.path) != 'cache') {
    directory = directory.parent;
  }
  return p.join(directory.path, 'dart-sdk', 'bin', 'dart.exe');
}

void main() {
  late DamLink link;
  late List<LinkEvent> events;

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('条件が満たされませんでした');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    events = <LinkEvent>[];
    final script = p.join(
      Directory.current.path,
      'test',
      'support',
      'fake_helper.dart',
    );
    link = DamLink(
      commandResolver: () => HelperCommand(dartExecutable(), <String>[
        script,
      ], Directory.current.path),
      environment: Platform.environment,
      onEvent: events.add,
      onPrepare: (_) async => (accepted: false, localUrl: '', error: ''),
    );
    await link.start(const <String, Object>{'replaceVideoUrls': true});
    await waitFor(() => link.isAttached);
  });

  tearDown(() => link.stop());

  test('検索と状態取得の応答を対応付ける', () async {
    final songs = await link.search('abc', RemoteSearchMode.keyword);
    expect(songs.single.title, 'abc');
    final state = await link.controlState();
    expect(state.key, 2);
  });

  test('DAM内で1件ずつの操作は要求順に直列化される', () async {
    final order = <String>[];
    await Future.wait(<Future<void>>[
      link
          .search('slow', RemoteSearchMode.keyword)
          .then((_) => order.add('slow')),
      link
          .search('fast', RemoteSearchMode.keyword)
          .then((_) => order.add('fast')),
    ]);
    expect(order, <String>['slow', 'fast']);
  });

  test('ヘルパーのエラー文字列を種別へ分類する', () async {
    await expectLater(
      link.search('busy', RemoteSearchMode.keyword),
      throwsA(
        isA<RemoteFailure>().having(
          (f) => f.kind,
          'kind',
          RemoteFailureKind.busy,
        ),
      ),
    );
  });

  test('巨大な行は破棄して通信を継続する', () async {
    final songs = await link.search('huge', RemoteSearchMode.keyword);
    expect(songs.single.title, 'huge');
    expect(
      events.whereType<LinkLog>().map((e) => e.message),
      contains(contains('上限')),
    );
  });

  test('ヘルパーが異常終了したら待機中の要求を失敗させ、自動で再起動する', () async {
    await expectLater(
      link.search('crash', RemoteSearchMode.keyword),
      throwsA(isA<RemoteFailure>()),
    );
    await waitFor(() => link.state == LinkState.helperExited);
    await waitFor(() => link.isAttached);
    expect(
      (await link.search('again', RemoteSearchMode.keyword)).single.title,
      'again',
    );
  });

  test('検索語の検証', () {
    expect(link.search('', RemoteSearchMode.keyword), throwsFormatException);
    expect(
      link.search('x' * 81, RemoteSearchMode.title),
      throwsFormatException,
    );
  });

  test('JsonLinesDecoder は上限を超えた行を組み立て途中で捨てる', () async {
    final input = Stream<List<int>>.fromIterable(<List<int>>[
      utf8.encode('{"a":1}\n${'y' * 50}'),
      utf8.encode('${'y' * 50}\n{"b":2}\n'),
    ]);
    final items = await input
        .transform(const JsonLinesDecoder(maximumLineBytes: 40))
        .toList();
    expect(items.where((i) => i.value != null).map((i) => i.value), <Object>[
      {'a': 1},
      {'b': 2},
    ]);
    expect(items.where((i) => i.error != null), hasLength(1));
  });

  test('不明なエラーは rejected、接続系は notConnected', () {
    expect(
      RemoteFailure.fromHelper('DAMに接続されていません').kind,
      RemoteFailureKind.notConnected,
    );
    expect(
      RemoteFailure.fromHelper('invalid or expired search result').kind,
      RemoteFailureKind.expired,
    );
    expect(RemoteFailure.fromHelper('何か').kind, RemoteFailureKind.rejected);
  });
}
