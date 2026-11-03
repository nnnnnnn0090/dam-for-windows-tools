import 'dart:typed_data';

import 'local_songs.dart';

/// 標準MIDIファイル内の1トラックから取り出した旋律の候補です。
class MidiTrack {
  const MidiTrack({
    required this.index,
    required this.name,
    required this.notes,
  });

  final int index;
  final String name;

  /// 同時に鳴る音は最も高い音だけを残し、時間順に重ならない形にそろえた旋律です。
  final List<MelodyNote> notes;

  int get lowestPitch =>
      notes.map((n) => n.pitch).reduce((a, b) => a < b ? a : b);
  int get highestPitch =>
      notes.map((n) => n.pitch).reduce((a, b) => a > b ? a : b);
}

class MidiFormatException implements Exception {
  const MidiFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 標準MIDIファイル（SMF 形式0・1）を読み、旋律の候補になるトラックを返します。
///
/// 時間はテンポの変化を反映したミリ秒にします。ドラム（チャンネル10）と、音の無い
/// トラックは含めません。
List<MidiTrack> parseMidiMelodies(Uint8List bytes) {
  final reader = _Reader(bytes);
  if (reader.remaining < 14 || reader.string(4) != 'MThd') {
    throw const MidiFormatException('MIDIファイルではありません');
  }
  final headerLength = reader.u32();
  final format = reader.u16();
  final trackCount = reader.u16();
  final division = reader.u16();
  if (headerLength < 6) throw const MidiFormatException('MIDIの見出しが不正です');
  reader.skip(headerLength - 6);
  if (format > 1) {
    throw const MidiFormatException('対応していないMIDI形式です（形式2）');
  }
  if (division & 0x8000 != 0) {
    throw const MidiFormatException('時間の単位がSMPTEのMIDIには対応していません');
  }
  if (division == 0) throw const MidiFormatException('MIDIの分解能が不正です');

  final tempos = <(int, int)>[(0, 500000)]; // (tick, マイクロ秒/四分音符)
  final rawTracks = <_RawTrack>[];
  for (var i = 0; i < trackCount && reader.remaining >= 8; i++) {
    final id = reader.string(4);
    final length = reader.u32();
    final end = reader.position + length;
    if (end > bytes.length) {
      throw const MidiFormatException('MIDIのトラックが途中で切れています');
    }
    if (id == 'MTrk') {
      rawTracks.add(_readTrack(reader, end, tempos, rawTracks.length));
    }
    reader.position = end;
  }
  tempos.sort((a, b) => a.$1.compareTo(b.$1));

  double toMs(int tick) {
    var ms = 0.0;
    var lastTick = 0;
    var tempo = 500000;
    for (final change in tempos) {
      if (change.$1 > tick) break;
      ms += (change.$1 - lastTick) * tempo / division / 1000;
      lastTick = change.$1;
      tempo = change.$2;
    }
    return ms + (tick - lastTick) * tempo / division / 1000;
  }

  final tracks = <MidiTrack>[];
  for (final raw in rawTracks) {
    final notes = _monophonic(<MelodyNote>[
      for (final n in raw.notes)
        MelodyNote(toMs(n.$1).round(), toMs(n.$2).round(), n.$3),
    ]);
    if (notes.isEmpty) continue;
    tracks.add(
      MidiTrack(
        index: raw.index,
        name: raw.name.isEmpty ? 'トラック${raw.index + 1}' : raw.name,
        notes: notes,
      ),
    );
  }
  return tracks;
}

class _RawTrack {
  _RawTrack(this.index);

  final int index;
  String name = '';

  /// (開始tick, 終了tick, 音高)
  final List<(int, int, int)> notes = <(int, int, int)>[];
}

_RawTrack _readTrack(
  _Reader reader,
  int end,
  List<(int, int)> tempos,
  int index,
) {
  final track = _RawTrack(index);
  final open = <int, int>{}; // チャンネルと音高 -> 開始tick
  var tick = 0;
  var status = 0;
  while (reader.position < end) {
    tick += reader.variable();
    final first = reader.u8();
    if (first == 0xff) {
      final type = reader.u8();
      final length = reader.variable();
      final data = reader.take(length);
      if (type == 0x51 && length == 3) {
        tempos.add((tick, (data[0] << 16) | (data[1] << 8) | data[2]));
      } else if (type == 0x03 && track.name.isEmpty) {
        track.name = String.fromCharCodes(data.where((b) => b >= 0x20));
      }
      continue;
    }
    if (first == 0xf0 || first == 0xf7) {
      reader.skip(reader.variable());
      continue;
    }
    int? data1;
    if (first & 0x80 != 0) {
      status = first;
    } else {
      data1 = first; // ランニングステータス
    }
    final kind = status & 0xf0;
    final channel = status & 0x0f;
    data1 ??= reader.u8();
    final data2 = (kind == 0xc0 || kind == 0xd0) ? 0 : reader.u8();
    if (channel == 9) continue; // ドラムは旋律に使わない
    final key = channel * 128 + data1;
    if (kind == 0x90 && data2 > 0) {
      final started = open[key];
      if (started != null && tick > started) {
        track.notes.add((started, tick, data1));
      }
      open[key] = tick;
    } else if (kind == 0x80 || (kind == 0x90 && data2 == 0)) {
      final started = open.remove(key);
      if (started != null && tick > started) {
        track.notes.add((started, tick, data1));
      }
    }
  }
  return track;
}

/// 同じ時刻に始まる音は最も高い音を残し、重なる音は前の音の終わりを削ります。
List<MelodyNote> _monophonic(List<MelodyNote> notes) {
  final sorted = <MelodyNote>[...notes]
    ..sort((a, b) {
      final byStart = a.startMs.compareTo(b.startMs);
      return byStart != 0 ? byStart : b.pitch.compareTo(a.pitch);
    });
  final result = <MelodyNote>[];
  for (final note in sorted) {
    if (result.isNotEmpty && result.last.startMs == note.startMs) continue;
    if (result.isNotEmpty && result.last.endMs > note.startMs) {
      final previous = result.removeLast();
      if (note.startMs > previous.startMs) {
        result.add(MelodyNote(previous.startMs, note.startMs, previous.pitch));
      }
    }
    if (note.endMs > note.startMs) result.add(note);
  }
  return result;
}

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int position = 0;

  int get remaining => bytes.length - position;

  int u8() {
    if (position >= bytes.length) {
      throw const MidiFormatException('MIDIが途中で終わっています');
    }
    return bytes[position++];
  }

  int u16() => (u8() << 8) | u8();

  int u32() => (u16() << 16) | u16();

  String string(int length) => String.fromCharCodes(take(length));

  Uint8List take(int length) {
    if (length < 0 || position + length > bytes.length) {
      throw const MidiFormatException('MIDIが途中で終わっています');
    }
    final view = Uint8List.sublistView(bytes, position, position + length);
    position += length;
    return view;
  }

  void skip(int length) => take(length);

  int variable() {
    var value = 0;
    for (var i = 0; i < 4; i++) {
      final b = u8();
      value = (value << 7) | (b & 0x7f);
      if (b & 0x80 == 0) return value;
    }
    throw const MidiFormatException('MIDIの時間の値が不正です');
  }
}
