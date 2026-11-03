import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/local_songs.dart';
import '../domain/settings.dart';
import '../domain/tracks.dart';
import '../domain/values.dart';
import 'json_store.dart';
import 'random_token.dart';

/// `settings.json` の読み書きです。形式はv1と同一です。
class SettingsStore {
  SettingsStore(File file)
    : _store = JsonFileStore(file, maximumBytes: 64 * 1024);

  final JsonFileStore _store;

  /// 無ければ既定値を返します。壊れていれば退避して例外を投げます。
  Future<AppSettings> load() async {
    final json = jsonObject(await _store.read());
    return json == null ? const AppSettings() : AppSettings.fromJson(json);
  }

  Future<void> save(AppSettings settings) => _store.write(settings.toJson());
}

/// `local_songs.json` の読み書きです。曲番号の順に保存します。
class LocalSongStore {
  LocalSongStore(File file)
    : _store = JsonFileStore(file, maximumBytes: 16 * 1024 * 1024);

  final JsonFileStore _store;

  Future<List<LocalSong>> load() async {
    final raw = await _store.read();
    final seen = <String>{};
    return <LocalSong>[
      for (final item in raw is List ? raw : const <Object?>[])
        if (jsonObject(item) case final json?)
          if (LocalSong.fromJson(json) case final song?)
            if (seen.add(song.requestNo)) song,
    ]..sort((a, b) => a.requestNo.compareTo(b.requestNo));
  }

  Future<void> save(List<LocalSong> songs) =>
      _store.write(<Object>[for (final song in songs) song.toJson()]);
}

/// `history.json` の読み書きです。形式はv1と同じ「古い順の配列」です。
///
/// アプリ内では新しい順で扱い、上限を超えたら古い記録から捨てます（v1は上限到達後に
/// 新しい曲が保存されませんでした）。同じ動画IDが複数あれば最も新しいものを残します。
class HistoryStore {
  HistoryStore(File file)
    : _store = JsonFileStore(file, maximumBytes: 8 * 1024 * 1024);

  static const int maximumRecords = 10000;

  final JsonFileStore _store;

  /// 新しい順の履歴を返します。
  Future<List<TrackRecord>> load() async {
    final raw = await _store.read();
    final items = raw is List ? raw : const <Object?>[];
    final seen = <String>{};
    final newestFirst = <TrackRecord>[];
    for (final item in items.reversed) {
      final object = jsonObject(item);
      if (object == null) continue;
      final record = TrackRecord.fromJson(object);
      if (record.videoId.isEmpty || !seen.add(record.videoId)) continue;
      newestFirst.add(record);
      if (newestFirst.length == maximumRecords) break;
    }
    return newestFirst;
  }

  /// 新しい順の履歴を保存します。
  Future<void> save(List<TrackRecord> newestFirst) =>
      _store.write(<Map<String, String>>[
        for (final record in newestFirst.take(maximumRecords).toList().reversed)
          record.toJson(),
      ]);
}

/// 利用者が選んだ差し替え動画を `videos/<動画ID>.<拡張子>` として管理します。
class ManualVideoStore {
  ManualVideoStore(this.directory);

  static const List<String> extensions = <String>[
    'mp4',
    'mkv',
    'mov',
    'avi',
    'webm',
    'm2ts',
    'ts',
  ];

  final Directory directory;

  /// 動画IDごとに最も新しいファイルを返します。取り込み途中の残骸は消します。
  Future<Map<String, File>> load() async {
    await directory.create(recursive: true);
    final newest = <String, (File, DateTime)>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.importing')) {
        await entity.delete().catchError((Object _) => entity);
        continue;
      }
      final videoId = _videoIdOf(entity.path);
      if (videoId.isEmpty) continue;
      final modified = await entity.lastModified();
      final current = newest[videoId];
      if (current == null || modified.isAfter(current.$2)) {
        newest[videoId] = (entity, modified);
      }
    }
    return <String, File>{
      for (final entry in newest.entries) entry.key: entry.value.$1,
    };
  }

  /// `source` を複製して登録します。呼び出し側は事前に該当動画の配信を止めます。
  ///
  /// [onProgress] には、複製したバイト数と全体のバイト数が届きます。
  Future<File> import(
    String videoId,
    File source, {
    void Function(int copied, int total)? onProgress,
  }) async {
    if (normalizeVideoAssetId(videoId) != videoId || videoId.isEmpty) {
      throw ArgumentError('動画IDが不正です');
    }
    final extension = p
        .extension(source.path)
        .toLowerCase()
        .replaceFirst('.', '');
    if (!extensions.contains(extension)) {
      throw ArgumentError('対応していない動画形式です (.$extension)');
    }
    final length = await source.length();
    if (length <= 0) throw ArgumentError('空の動画は指定できません');

    await directory.create(recursive: true);
    final destination = File(p.join(directory.path, '$videoId.$extension'));
    if (!p.equals(source.absolute.path, destination.absolute.path)) {
      final temporary = File(
        p.join(directory.path, '$videoId.${randomHex(8)}.importing'),
      );
      try {
        var copied = 0;
        final sink = temporary.openWrite();
        try {
          await sink.addStream(
            source.openRead().map((chunk) {
              copied += chunk.length;
              onProgress?.call(copied, length);
              return chunk;
            }),
          );
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (await temporary.length() != length) {
          throw FileSystemException('動画の複製を検証できませんでした', source.path);
        }
        await temporary.rename(destination.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
    await _deleteOthers(videoId, keep: destination.path);
    return destination;
  }

  /// 登録を解除します。呼び出し側は事前に該当動画の配信を止めます。
  Future<void> remove(String videoId) => _deleteOthers(videoId);

  Future<void> _deleteOthers(String videoId, {String? keep}) async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || _videoIdOf(entity.path) != videoId) continue;
      if (keep != null && p.equals(entity.path, keep)) continue;
      await entity.delete();
    }
  }

  static String _videoIdOf(String path) {
    final extension = p.extension(path).toLowerCase().replaceFirst('.', '');
    if (!extensions.contains(extension)) return '';
    return normalizeVideoAssetId(p.basenameWithoutExtension(path));
  }
}
