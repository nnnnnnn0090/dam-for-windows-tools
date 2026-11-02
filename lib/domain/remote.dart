import 'values.dart';

/// リモコンの検索元です。`wireName` は接続ヘルパーとブラウザで共通の名前です。
enum RemoteSearchMode {
  keyword('keyword', needsQuery: true),
  title('title', needsQuery: true),
  artist('artist', needsQuery: true),
  ranking('ranking'),
  newReleases('new'),
  favorites('favorites'),
  history('history');

  const RemoteSearchMode(this.wireName, {this.needsQuery = false});
  final String wireName;
  final bool needsQuery;

  /// ブラウザの `search` APIで選べるモードです。historyは専用APIから使います。
  static RemoteSearchMode? fromBrowser(Object? value) {
    for (final mode in values) {
      if (mode != history && mode.wireName == value) return mode;
    }
    return null;
  }
}

enum RemotePlayType { standard, guideVocal, artistVideo }

enum RemoteReservationMode { normal, cutIn, originalKey }

enum RemoteControlAction {
  pause,
  resume,
  stop,
  restart,
  keyDown,
  keyUp,
  keyReset,
  scoringOn,
  scoringOff,
  confirmYes,
  confirmNo,
}

enum RemoteQueueAction { remove, moveUp, moveDown }

/// `name` が一致する列挙値を返します。一致しなければ `null` です。
T? enumByName<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

final RegExp _songTokenPattern = RegExp(r'^[0-9A-Za-z_-]{1,160}$');
final RegExp _queueTokenPattern = RegExp(r'^q_[cn]_[0-9]{1,6}$');

bool isSongToken(Object? value) =>
    value is String && _songTokenPattern.hasMatch(value);

bool isQueueToken(Object? value) =>
    value is String && _queueTokenPattern.hasMatch(value);

/// 検索結果・お気に入り・履歴に共通する曲（または歌手）1行です。
class RemoteSong {
  const RemoteSong({
    required this.token,
    required this.videoId,
    required this.artist,
    required this.title,
    this.isArtist = false,
    this.favorite = false,
    this.history = false,
  });

  final String token;
  final String videoId;
  final String artist;
  final String title;
  final bool isArtist;
  final bool favorite;
  final bool history;

  bool get isDisplayable =>
      token.isNotEmpty &&
      (videoId.isNotEmpty || isArtist || favorite || history);

  factory RemoteSong.fromJson(Map<String, Object?> json) => RemoteSong(
    token: isSongToken(json['token']) ? json['token']! as String : '',
    videoId: normalizeVideoAssetId(json['videoId']),
    artist: sanitizeText(json['artist'], maximumLength: 300),
    title: sanitizeText(json['title'], maximumLength: 300),
    isArtist: json['kind'] == 'artist',
    favorite: json['favorite'] == true,
    history: json['history'] == true,
  );

  Map<String, Object> toJson() => <String, Object>{
    'token': token,
    'videoId': videoId,
    'artist': artist,
    'title': title,
    'kind': isArtist ? 'artist' : 'song',
    'favorite': favorite,
    'history': history,
  };
}

/// 予約条件の選択に必要な曲詳細です。
class RemoteSongDetail {
  const RemoteSongDetail({
    required this.videoId,
    required this.startLyric,
    required this.originalKey,
    required this.playTypes,
  });

  final String videoId;
  final String startLyric;
  final int originalKey;
  final List<RemotePlayType> playTypes;

  factory RemoteSongDetail.fromJson(Map<String, Object?> json) {
    final raw = json['playTypes'];
    final names = raw is List ? raw.toSet() : const <Object?>{};
    return RemoteSongDetail(
      videoId: normalizeVideoAssetId(json['videoId']),
      startLyric: sanitizeText(json['startLyric'], maximumLength: 300),
      originalKey: clampedInt(json['originalKey'], minimumKey, maximumKey),
      playTypes: <RemotePlayType>[
        for (final type in RemotePlayType.values)
          if (names.contains(type.name)) type,
      ],
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'videoId': videoId,
    'startLyric': startLyric,
    'originalKey': originalKey,
    'playTypes': <String>[for (final type in playTypes) type.name],
  };
}

class RemoteReservationOptions {
  const RemoteReservationOptions({
    required this.mode,
    required this.key,
    required this.scoring,
    required this.playType,
  });

  final RemoteReservationMode mode;
  final int key;
  final bool scoring;
  final RemotePlayType playType;
}

class RemoteReservationResult {
  const RemoteReservationResult({
    required this.accepted,
    required this.message,
    this.videoId = '',
    this.artist = '',
    this.title = '',
  });

  final bool accepted;
  final String message;
  final String videoId;
  final String artist;
  final String title;

  factory RemoteReservationResult.fromJson(Map<String, Object?> json) =>
      RemoteReservationResult(
        accepted: json['accepted'] == true,
        message: sanitizeText(json['message'], maximumLength: 500),
        videoId: normalizeVideoAssetId(json['videoId']),
        artist: sanitizeText(json['artist'], maximumLength: 300),
        title: sanitizeText(json['title'], maximumLength: 300),
      );

  Map<String, Object> toJson() => <String, Object>{
    'accepted': accepted,
    'message': message,
    'videoId': videoId,
    'artist': artist,
    'title': title,
  };
}

class RemoteFavoriteResult {
  const RemoteFavoriteResult({
    required this.accepted,
    required this.favorite,
    required this.message,
  });

  final bool accepted;
  final bool favorite;
  final String message;

  factory RemoteFavoriteResult.fromJson(Map<String, Object?> json) =>
      RemoteFavoriteResult(
        accepted: json['accepted'] == true,
        favorite: json['favorite'] == true,
        message: sanitizeText(json['message'], maximumLength: 500),
      );

  Map<String, Object> toJson() => <String, Object>{
    'accepted': accepted,
    'favorite': favorite,
    'message': message,
  };
}

/// DAM本体に表示中の「はい／いいえ」確認です。
class RemoteConfirmation {
  const RemoteConfirmation({required this.message, required this.selectedYes});

  final String message;
  final bool selectedYes;

  factory RemoteConfirmation.fromJson(Map<String, Object?> json) =>
      RemoteConfirmation(
        message: sanitizeText(json['message'], maximumLength: 500),
        selectedYes: json['selected'] != 'no',
      );

  Map<String, Object> toJson() => <String, Object>{
    'message': message,
    'selected': selectedYes ? 'yes' : 'no',
  };
}

/// リモコンへ公開する接続・演奏状態です。
class RemoteControlState {
  const RemoteControlState({
    required this.connected,
    required this.playing,
    required this.paused,
    required this.key,
    this.damScoring = false,
    this.videoId = '',
    this.artist = '',
    this.title = '',
    this.confirmation,
  });

  final bool connected;
  final bool playing;
  final bool paused;
  final int key;
  final bool damScoring;
  final String videoId;
  final String artist;
  final String title;
  final RemoteConfirmation? confirmation;

  factory RemoteControlState.fromJson(Map<String, Object?> json) {
    final confirmation = jsonObject(json['confirmation']);
    return RemoteControlState(
      connected: json['connected'] == true,
      playing: json['playing'] == true,
      paused: json['paused'] == true,
      key: clampedInt(json['key'], minimumKey, maximumKey),
      damScoring: json['damScoring'] == true,
      videoId: normalizeVideoAssetId(json['videoId']),
      artist: sanitizeText(json['artist'], maximumLength: 300),
      title: sanitizeText(json['title'], maximumLength: 300),
      confirmation: confirmation == null
          ? null
          : RemoteConfirmation.fromJson(confirmation),
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'connected': connected,
    'playing': playing,
    'paused': paused,
    'key': key,
    'damScoring': damScoring,
    'videoId': videoId,
    'artist': artist,
    'title': title,
    'confirmation': ?confirmation?.toJson(),
  };
}

/// DAMの予約一覧1行です。
class RemoteQueueEntry {
  const RemoteQueueEntry({
    required this.token,
    required this.queueId,
    required this.index,
    required this.cutIn,
    required this.artist,
    required this.title,
  });

  final String token;
  final int queueId;
  final int index;
  final bool cutIn;
  final String artist;
  final String title;

  factory RemoteQueueEntry.fromJson(Map<String, Object?> json) =>
      RemoteQueueEntry(
        token: isQueueToken(json['token']) ? json['token']! as String : '',
        queueId: clampedInt(json['queueId'], 0, 0x7fffffff),
        index: clampedInt(json['index'], 0, 1000),
        cutIn: json['cutIn'] == true,
        artist: sanitizeText(json['artist'], maximumLength: 300),
        title: sanitizeText(json['title'], maximumLength: 300),
      );

  Map<String, Object> toJson() => <String, Object>{
    'token': token,
    'queueId': queueId,
    'index': index,
    'cutIn': cutIn,
    'artist': artist,
    'title': title,
  };
}
