import 'dart:convert';
import 'dart:io';

import 'package:dam_for_windows_tools/domain/settings.dart';
import 'package:dam_for_windows_tools/domain/tracks.dart';
import 'package:dam_for_windows_tools/infra/json_store.dart';
import 'package:dam_for_windows_tools/infra/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dam_tools_store_');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  group('JsonFileStore', () {
    test('並行書き込みでも最後の要求内容が完全な形で残る', () async {
      final store = JsonFileStore(
        File(p.join(temp.path, 'a.json')),
        maximumBytes: 1 << 20,
      );
      await Future.wait(<Future<void>>[
        for (var i = 0; i < 50; i++)
          store.write(<String, Object>{'n': i, 'pad': 'x' * (i * 100)}),
      ]);
      final value = await store.read() as Map<String, Object?>;
      expect(value['n'], 49);
      final leftovers = temp.listSync().where((e) => e.path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });

    test('壊れたファイルは複製で退避し、例外を投げる', () async {
      final file = File(p.join(temp.path, 'b.json'))
        ..writeAsStringSync('{broken');
      final store = JsonFileStore(file, maximumBytes: 1 << 20);
      await expectLater(store.read(), throwsA(isA<CorruptFileException>()));
      final backups = temp.listSync().where(
        (e) => p.basename(e.path).startsWith('b.json.corrupt-'),
      );
      expect(backups, hasLength(1));
      expect(File(backups.single.path).readAsStringSync(), '{broken');
    });

    test('上限超過も破損として扱う', () async {
      final file = File(p.join(temp.path, 'c.json'))
        ..writeAsStringSync(jsonEncode(List<int>.filled(100, 1)));
      final store = JsonFileStore(file, maximumBytes: 10);
      await expectLater(store.read(), throwsA(isA<CorruptFileException>()));
    });
  });

  group('HistoryStore', () {
    test('v1形式(古い順)を新しい順で読み、重複は新しい方を残す', () async {
      final file = File(p.join(temp.path, 'history.json'))
        ..writeAsStringSync(
          jsonEncode(<Object>[
            <String, String>{'videoId': '1-1', 'artist': 'A', 'title': 'old'},
            <String, String>{'videoId': '2-2', 'artist': 'B', 'title': 'b'},
            <String, String>{'videoId': '1-1', 'artist': 'A', 'title': 'new'},
            <String, String>{'videoId': '../x', 'artist': '', 'title': ''},
          ]),
        );
      final records = await HistoryStore(file).load();
      expect(records.map((r) => r.videoId), <String>['1-1', '2-2']);
      expect(records.first.title, 'new');
    });

    test('保存はv1と同じ古い順の配列で、上限超過分は古い方から捨てる', () async {
      final file = File(p.join(temp.path, 'history.json'));
      final store = HistoryStore(file);
      final newestFirst = <TrackRecord>[
        for (var i = HistoryStore.maximumRecords + 5; i > 0; i--)
          TrackRecord(videoId: '$i-0', artist: '', title: ''),
      ];
      await store.save(newestFirst);
      final raw = jsonDecode(file.readAsStringSync()) as List<Object?>;
      expect(raw, hasLength(HistoryStore.maximumRecords));
      expect(
        (raw.last! as Map)['videoId'],
        '${HistoryStore.maximumRecords + 5}-0',
      );
      final loaded = await store.load();
      expect(loaded.first.videoId, '${HistoryStore.maximumRecords + 5}-0');
    });
  });

  group('SettingsStore', () {
    test('無ければ既定値、旧キーscoringEnabledも読む', () async {
      final file = File(p.join(temp.path, 'settings.json'));
      final store = SettingsStore(file);
      expect(await store.load(), const AppSettings());
      file.writeAsStringSync(
        jsonEncode(<String, Object>{'scoringEnabled': false, 'skipMs': 99999}),
      );
      final loaded = await store.load();
      expect(loaded.scoringOverlayEnabled, isFalse);
      expect(loaded.skipMs, AppSettings.maximumSkipMs);
    });
  });

  group('ManualVideoStore', () {
    test('取り込み・別拡張子の置き換え・解除', () async {
      final store = ManualVideoStore(Directory(p.join(temp.path, 'videos')));
      final mp4 = File(p.join(temp.path, 'a.mp4'))..writeAsBytesSync([1, 2, 3]);
      final mkv = File(p.join(temp.path, 'b.mkv'))..writeAsBytesSync([4, 5]);
      await store.import('6184-92', mp4);
      await store.import('6184-92', mkv);
      final loaded = await store.load();
      expect(p.basename(loaded['6184-92']!.path), '6184-92.mkv');
      expect(store.directory.listSync(), hasLength(1));
      await store.remove('6184-92');
      expect(await store.load(), isEmpty);
    });

    test('取り込みの進み具合を、複製したバイト数で知らせる', () async {
      final store = ManualVideoStore(Directory(p.join(temp.path, 'videos')));
      // 読み込みが複数回に分かれる大きさ（約3MB）
      final bytes = List<int>.generate(3 * 1024 * 1024 + 7, (i) => i % 251);
      final source = File(p.join(temp.path, 'big.mp4'))
        ..writeAsBytesSync(bytes);
      final reports = <(int, int)>[];
      final stored = await store.import(
        '6184-92',
        source,
        onProgress: (copied, total) => reports.add((copied, total)),
      );
      expect(reports.length, greaterThan(1));
      expect(reports.every((r) => r.$2 == bytes.length), isTrue);
      for (var i = 1; i < reports.length; i++) {
        expect(reports[i].$1, greaterThan(reports[i - 1].$1));
      }
      expect(reports.last.$1, bytes.length);
      expect(stored.readAsBytesSync(), bytes);
    });

    test('不正なIDや形式は拒否する', () async {
      final store = ManualVideoStore(Directory(p.join(temp.path, 'videos')));
      final txt = File(p.join(temp.path, 'a.txt'))..writeAsBytesSync([1]);
      final mp4 = File(p.join(temp.path, 'a.mp4'))..writeAsBytesSync([1]);
      expect(store.import('6184-92', txt), throwsArgumentError);
      expect(store.import('..\\evil', mp4), throwsArgumentError);
    });
  });
}
