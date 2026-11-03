import 'dart:io';

import 'package:dam_for_windows_tools/domain/local_songs.dart';
import 'package:dam_for_windows_tools/infra/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('曲番号は 9999-01 から空いている最小の番号を使う', () {
    expect(LocalSong.nextNumber(const <String>[]), '9999-01');
    expect(
      LocalSong.nextNumber(const <String>['9999-01', '9999-03']),
      '9999-02',
    );
    expect(
      LocalSong.nextNumber(<String>[
        for (var i = 1; i <= 99; i++) '9999-${i.toString().padLeft(2, '0')}',
      ]),
      isNull,
    );
    expect(LocalSong.isLocalNumber('9999-01'), isTrue);
    expect(LocalSong.isLocalNumber('9999-00'), isFalse);
    expect(LocalSong.isLocalNumber('6343-03'), isFalse);
  });

  test('保存して読み直すと同じ内容になり、不正な行と重複は捨てる', () async {
    final directory = await Directory.systemTemp.createTemp('local_songs');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(p.join(directory.path, 'local_songs.json'));
    final store = LocalSongStore(file);
    const songs = <LocalSong>[
      LocalSong(
        requestNo: '9999-02',
        title: 'b',
        artist: 'B',
        playtimeSeconds: 61,
      ),
      LocalSong(
        requestNo: '9999-01',
        title: 'where the light leads us',
        artist: 'fripSide',
        titleYomi: 'ホエアザライトリーズアス',
        artistYomi: 'フリップサイド',
        playtimeSeconds: 245,
        melody: <MelodyNote>[
          MelodyNote(10000, 10450, 71),
          MelodyNote(10500, 10950, 67),
        ],
      ),
    ];
    await store.save(songs);
    final loaded = await store.load();
    expect(loaded.map((s) => s.requestNo), <String>['9999-01', '9999-02']);
    expect(loaded.first, songs[1]);
    expect(loaded.first.hasScore, isTrue);
    expect(loaded.first.melodyFlat, <int>[10000, 10450, 71, 10500, 10950, 67]);
    expect(loaded.last.hasScore, isFalse);

    await file.writeAsString(
      '[{"requestNo":"9999-01","title":"a","artist":"A"},'
      '{"requestNo":"9999-01","title":"dup","artist":"A"},'
      '{"requestNo":"6343-03","title":"real","artist":"A"},'
      '{"requestNo":"9999-05","title":"","artist":"A"},"x"]',
    );
    final cleaned = await LocalSongStore(file).load();
    expect(cleaned.map((s) => s.title), <String>['a']);
  });

  test('旋律は不正な音符を捨て、採点用のファイルには平らな配列で渡す', () {
    final song = LocalSong.fromJson(<String, Object?>{
      'requestNo': '9999-01',
      'title': 't',
      'artist': 'a',
      'melody': <Object>[
        1000, 1500, 60, // 正常
        3000, 2000, 60, // 終わりが開始より前
        4000, 4500, 5, // 音高が範囲外
        'x', 1, 1,
        5000, 5500, 64, // 正常
        6000, 6500, // 端数は無視
      ],
    });
    expect(song, isNotNull);
    expect(song!.melody.length, 2);
    expect(song.melodyFlat, <int>[1000, 1500, 60, 5000, 5500, 64]);
    final helper = song.toHelperJson(scorePath: r'C:\data\9999-01.json');
    expect(helper['scorePath'], r'C:\data\9999-01.json');
    expect(helper.containsKey('melody'), isFalse, reason: '音符は大きいのでファイルで渡す');
    expect(
      song.copyWith(melody: const <MelodyNote>[]).toHelperJson(scorePath: 'x'),
      isNot(contains('scorePath')),
    );
  });
}
