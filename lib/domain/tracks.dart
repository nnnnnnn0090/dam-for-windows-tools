import 'values.dart';

/// 永続化する再生履歴1件です。URL・時刻・ファイルパスは保持しません。
class TrackRecord {
  const TrackRecord({
    required this.videoId,
    required this.artist,
    required this.title,
  });

  final String videoId;
  final String artist;
  final String title;

  TrackRecord copyWith({String? artist, String? title}) => TrackRecord(
    videoId: videoId,
    artist: artist ?? this.artist,
    title: title ?? this.title,
  );

  Map<String, String> toJson() => <String, String>{
    'videoId': videoId,
    'artist': artist,
    'title': title,
  };

  factory TrackRecord.fromJson(Map<String, Object?> json) => TrackRecord(
    videoId: normalizeVideoAssetId(json['videoId']),
    artist: sanitizeText(json['artist'], maximumLength: 300),
    title: sanitizeText(json['title'], maximumLength: 300),
  );
}

/// 1回の再生がローカル配信のどこまで進んだかを表します。
enum PlaybackStage {
  detected('検知'),
  registered('登録'),
  rewritten('URL置換'),
  preparing('HLS準備'),
  manifestRequested('マニフェスト要求'),
  streaming('配信中'),
  officialFallback('公式退避'),
  failed('失敗');

  const PlaybackStage(this.label);
  final String label;
}

/// DAMの曲情報応答から得た、動画IDと曲名を結び付ける候補です。
class MetadataCandidate {
  const MetadataCandidate({
    required this.ids,
    required this.artist,
    required this.title,
  });

  final List<String> ids;
  final String artist;
  final String title;

  factory MetadataCandidate.fromJson(Map<String, Object?> json) {
    final rawIds = json['ids'];
    return MetadataCandidate(
      ids: rawIds is List
          ? rawIds
                .map(normalizeVideoAssetId)
                .where((id) => id.isNotEmpty)
                .toList(growable: false)
          : const <String>[],
      artist: sanitizeText(json['artist'], maximumLength: 300),
      title: sanitizeText(json['title'], maximumLength: 300),
    );
  }
}

/// DAMが再生しようとしている動画と、品質別の上流URLです。
class PlaybackDescriptor {
  const PlaybackDescriptor({
    required this.videoId,
    required this.highUrl,
    required this.lowUrl,
  });

  final String videoId;
  final Uri? highUrl;
  final Uri? lowUrl;

  /// highを優先し、重複を除いた上流候補です。
  List<Uri> get upstreamUrls => <Uri>{?highUrl, ?lowUrl}.toList();

  factory PlaybackDescriptor.fromJson(Map<String, Object?> json) =>
      PlaybackDescriptor(
        videoId: normalizeVideoAssetId(json['videoId']),
        highUrl: parseHttpUri(json['highUrl']),
        lowUrl: parseHttpUri(json['lowUrl']),
      );
}
