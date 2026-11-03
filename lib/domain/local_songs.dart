import 'values.dart';

/// DAMの配信にない曲を、このPCだけで追加したものです。
///
/// DAMの検索・曲情報・配信URLの応答へ付け足して、DAMの曲と同じように予約・再生します。
/// 動画は、曲番号を動画IDとした差し替え動画として保存します。
/// 採点の基準にする旋律の1音です（時間はミリ秒、音高はMIDIノート番号）。
class MelodyNote {
  const MelodyNote(this.startMs, this.endMs, this.pitch);

  final int startMs;
  final int endMs;
  final int pitch;

  @override
  bool operator ==(Object other) =>
      other is MelodyNote &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.pitch == pitch;

  @override
  int get hashCode => Object.hash(startMs, endMs, pitch);
}

class LocalSong {
  const LocalSong({
    required this.requestNo,
    required this.title,
    required this.artist,
    this.titleYomi = '',
    this.artistYomi = '',
    this.playtimeSeconds = 0,
    this.melody = const <MelodyNote>[],
  });

  /// 採点に使える音符の最大数です。
  static const int maximumMelodyNotes = 3000;

  /// ローカル曲に割り当てる曲番号の頭の4桁です。DAMの曲番号と重ならない範囲を使います。
  static const String numberPrefix = '9999';
  static const int maximumSongs = 99;

  /// `9999-01` の形です。
  final String requestNo;
  final String title;
  final String artist;

  /// 検索・並び替えに使う読み（ひらがな・カタカナ）です。
  final String titleYomi;
  final String artistYomi;

  /// 動画の長さ（秒）です。DAMの曲情報に表示されます。
  final int playtimeSeconds;

  /// 採点の基準にする旋律です。空なら、この曲は採点できません。
  final List<MelodyNote> melody;

  bool get hasScore => melody.isNotEmpty;

  /// 接続ヘルパーへ送る音符です（開始ms・終了ms・音高の繰り返し）。
  List<int> get melodyFlat => <int>[
    for (final note in melody) ...<int>[note.startMs, note.endMs, note.pitch],
  ];

  static bool isLocalNumber(String value) =>
      RegExp('^$numberPrefix-[0-9]{2}\$').hasMatch(value) &&
      value != '$numberPrefix-00';

  /// [used] と重ならない最小の曲番号です。空きがなければ `null` です。
  static String? nextNumber(Iterable<String> used) {
    final taken = used.toSet();
    for (var i = 1; i <= maximumSongs; i++) {
      final candidate = '$numberPrefix-${i.toString().padLeft(2, '0')}';
      if (!taken.contains(candidate)) return candidate;
    }
    return null;
  }

  LocalSong copyWith({
    String? title,
    String? artist,
    String? titleYomi,
    String? artistYomi,
    int? playtimeSeconds,
    List<MelodyNote>? melody,
  }) => LocalSong(
    requestNo: requestNo,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    titleYomi: titleYomi ?? this.titleYomi,
    artistYomi: artistYomi ?? this.artistYomi,
    playtimeSeconds: playtimeSeconds ?? this.playtimeSeconds,
    melody: melody ?? this.melody,
  );

  /// 保存形式です。旋律は軽くするため、開始・終了・音高を平らに並べます。
  Map<String, Object> toJson() => <String, Object>{
    'requestNo': requestNo,
    'title': title,
    'artist': artist,
    'titleYomi': titleYomi,
    'artistYomi': artistYomi,
    'playtime': playtimeSeconds,
    if (melody.isNotEmpty) 'melody': melodyFlat,
  };

  /// 接続ヘルパーへ送る形式です。音符は大きいため、曲ごとのファイル（[scorePath]）に書き、
  /// DAMの中のAgentがそのファイルを読みます。
  Map<String, Object> toHelperJson({String? scorePath}) => <String, Object>{
    'requestNo': requestNo,
    'title': title,
    'artist': artist,
    'titleYomi': titleYomi,
    'artistYomi': artistYomi,
    'playtime': playtimeSeconds,
    if (hasScore && scorePath != null) 'scorePath': scorePath,
  };

  /// 不正な行は `null` です。
  static LocalSong? fromJson(Map<String, Object?> json) {
    final requestNo = json['requestNo'];
    if (requestNo is! String || !isLocalNumber(requestNo)) return null;
    final title = sanitizeText(json['title'], maximumLength: 200);
    final artist = sanitizeText(json['artist'], maximumLength: 200);
    if (title.isEmpty) return null;
    final playtime = json['playtime'];
    final rawMelody = json['melody'];
    final melody = <MelodyNote>[];
    if (rawMelody is List) {
      for (var i = 0; i + 2 < rawMelody.length; i += 3) {
        final start = rawMelody[i];
        final end = rawMelody[i + 1];
        final pitch = rawMelody[i + 2];
        if (start is! num || end is! num || pitch is! num) continue;
        if (start < 0 || end <= start || pitch < 20 || pitch > 100) continue;
        melody.add(MelodyNote(start.toInt(), end.toInt(), pitch.toInt()));
        if (melody.length == maximumMelodyNotes) break;
      }
    }
    return LocalSong(
      requestNo: requestNo,
      title: title,
      artist: artist,
      titleYomi: sanitizeText(json['titleYomi'], maximumLength: 200),
      artistYomi: sanitizeText(json['artistYomi'], maximumLength: 200),
      playtimeSeconds: playtime is num ? playtime.clamp(0, 3600).toInt() : 0,
      melody: melody,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LocalSong &&
      other.requestNo == requestNo &&
      other.title == title &&
      other.artist == artist &&
      other.titleYomi == titleYomi &&
      other.artistYomi == artistYomi &&
      other.playtimeSeconds == playtimeSeconds &&
      _sameMelody(other.melody, melody);

  static bool _sameMelody(List<MelodyNote> a, List<MelodyNote> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    requestNo,
    title,
    artist,
    titleYomi,
    artistYomi,
    playtimeSeconds,
    melody.length,
  );
}
