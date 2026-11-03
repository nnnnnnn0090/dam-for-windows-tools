import 'dart:typed_data';

import 'package:dam_for_windows_tools/domain/local_songs.dart';
import 'package:dam_for_windows_tools/domain/midi_melody.dart';
import 'package:flutter_test/flutter_test.dart';

/// 標準MIDIファイル（形式1）を組み立てます。
Uint8List midi(List<List<int>> tracks, {int division = 480}) {
  final out = <int>[
    ...'MThd'.codeUnits,
    0,
    0,
    0,
    6,
    0,
    1,
    0,
    tracks.length,
    division >> 8,
    division & 0xff,
  ];
  for (final track in tracks) {
    out
      ..addAll('MTrk'.codeUnits)
      ..addAll(<int>[
        track.length >> 24,
        (track.length >> 16) & 0xff,
        (track.length >> 8) & 0xff,
        track.length & 0xff,
      ])
      ..addAll(track);
  }
  return Uint8List.fromList(out);
}

const List<int> endOfTrack = <int>[0, 0xff, 0x2f, 0];

void main() {
  test('テンポの変化を反映したミリ秒の音符を読み、ドラムは除く', () {
    final tempo = <int>[
      0, 0xff, 0x51, 3, 0x07, 0xa1, 0x20, // 120BPM（500000マイクロ秒）
      0x83, 0x60, 0xff, 0x51, 3, 0x0f, 0x42, 0x40, // tick 480 から 60BPM（1000000）
      ...endOfTrack,
    ];
    final melody = <int>[
      0, 0xff, 0x03, 6, ...'Melody'.codeUnits,
      0, 0x90, 60, 100, // tick 0: C4 on
      0x83, 0x60, 0x80, 60, 0, // tick 480 off（120BPMで500ms）
      0, 0x90, 64, 100, // tick 480: E4 on
      0x83, 0x60, 0x80, 64, 0, // tick 960 off（60BPMで480tick=1000ms）
      ...endOfTrack,
    ];
    final drums = <int>[0, 0x99, 36, 100, 0x60, 0x89, 36, 0, ...endOfTrack];
    final tracks = parseMidiMelodies(midi(<List<int>>[tempo, melody, drums]));
    expect(tracks.length, 1, reason: '音の無いトラックとドラムは含めない');
    expect(tracks.single.name, 'Melody');
    expect(tracks.single.notes, const <MelodyNote>[
      MelodyNote(0, 500, 60),
      MelodyNote(500, 1500, 64),
    ]);
  });

  test('同時に鳴る音は高い音を残し、重なる音は前の音を削り、ランニングステータスも読む', () {
    final track = <int>[
      0, 0x90, 60, 100,
      0, 0x90, 67, 100, // 同時に始まる -> 高い音(67)だけ
      0x78, 0x80, 67, 0, // 120tick
      0, 60, 0, // ランニングステータス（0x80）で 60 を終える
      0x78, 0x90, 62, 100, // tick 240
      0x78, 62, 0, // ランニングステータス（0x90 で音量0 = 終了）
      ...endOfTrack,
    ];
    final tracks = parseMidiMelodies(midi(<List<int>>[track]));
    expect(tracks.single.name, 'トラック1');
    expect(tracks.single.notes, const <MelodyNote>[
      MelodyNote(0, 125, 67),
      MelodyNote(250, 375, 62),
    ]);
    expect(tracks.single.lowestPitch, 62);
    expect(tracks.single.highestPitch, 67);
  });

  test('MIDIでないファイルや途中で切れたファイルは分かりやすい例外にする', () {
    expect(
      () => parseMidiMelodies(Uint8List.fromList('not a midi file'.codeUnits)),
      throwsA(isA<MidiFormatException>()),
    );
    final ok = midi(<List<int>>[
      <int>[0, 0x90, 60, 100, ...endOfTrack],
    ]);
    expect(
      () => parseMidiMelodies(Uint8List.sublistView(ok, 0, ok.length - 3)),
      throwsA(isA<MidiFormatException>()),
    );
  });
}
