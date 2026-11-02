import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../app_config.dart';
import '../domain/update.dart';
import '../domain/values.dart';
import 'native_bridge.dart';
import 'paths.dart';

/// GitHub Releasesから新版を探し、検証済みZIPを取得して `updater.exe` へ渡します。
///
/// 検証内容: 取得元ホスト（リダイレクトは追う前に検査）、宣言サイズ、
/// ZIPと同時に公開される `<zip>.sha256` との一致。展開後のファイル単位の検証と
/// 置き換え・ロールバックは `updater.exe` が行います。
class UpdateService {
  UpdateService({required this.paths, required this.bridge, HttpClient? client})
    : _client = client ?? HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..userAgent = 'DAMforWindowsTools/${AppConfig.productVersion}';

  static const int maximumArchiveBytes = 512 * 1024 * 1024;
  static const Duration readTimeout = Duration(seconds: 30);
  static final AppVersion currentVersion = AppVersion.tryParse(
    AppConfig.productVersion,
  )!;

  final AppPaths paths;
  final NativeBridge bridge;
  final HttpClient _client;

  bool get supported => paths.isPackaged;

  /// 新版があれば返します。無ければ `null` です。
  Future<AppUpdate?> check() async {
    final uri = Uri.parse(
      'https://api.github.com/repos/${AppConfig.githubRepository}/releases/latest',
    );
    final response = await _get(uri, accept: 'application/vnd.github+json');
    if (response.statusCode == HttpStatus.notFound) {
      await response.drain<void>();
      return null;
    }
    _expectOk(response);
    final body = utf8.decode(await _readAll(response, limit: 1024 * 1024));
    return parseRelease(
      jsonObject(jsonDecode(body)) ?? const <String, Object?>{},
    );
  }

  /// GitHubの `releases/latest` 応答から、適用できる更新を選びます。
  static AppUpdate? parseRelease(Map<String, Object?> release) {
    if (release['draft'] == true || release['prerelease'] == true) return null;
    final tag = release['tag_name'];
    final version = tag is String ? AppVersion.tryParse(tag) : null;
    if (version == null || !(version > currentVersion)) return null;

    final archiveName = 'DAMforWindowsTools-$version-win-x64.zip';
    Map<String, Object?>? archive;
    Map<String, Object?>? checksum;
    final assets = release['assets'];
    for (final raw in assets is List ? assets : const <Object?>[]) {
      final asset = jsonObject(raw);
      if (asset == null || asset['state'] != 'uploaded') continue;
      if (asset['name'] == archiveName) archive = asset;
      if (asset['name'] == '$archiveName.sha256') checksum = asset;
    }
    if (archive == null || checksum == null) return null;
    final archiveUri = _releaseAssetUri(archive['browser_download_url']);
    final checksumUri = _releaseAssetUri(checksum['browser_download_url']);
    final size = archive['size'];
    if (archiveUri == null || checksumUri == null) return null;
    if (size is! int || size <= 0 || size > maximumArchiveBytes) return null;
    final notes = release['body'];
    return AppUpdate(
      version: version,
      archiveUri: archiveUri,
      archiveName: archiveName,
      archiveSize: size,
      checksumUri: checksumUri,
      notes: notes is String ? sanitizeNotes(notes) : '',
    );
  }

  /// 改行は残し、制御文字を除いて4000文字までにします。
  static String sanitizeNotes(String notes) {
    final cleaned = notes
        .replaceAll('\r\n', '\n')
        .replaceAll(RegExp(r'[\x00-\x09\x0b-\x1f\x7f]'), '')
        .trim();
    return cleaned.length <= 4000 ? cleaned : '${cleaned.substring(0, 4000)}…';
  }

  static Uri? _releaseAssetUri(Object? value) {
    final uri = value is String ? Uri.tryParse(value) : null;
    final prefix = '/${AppConfig.githubRepository}/releases/download/';
    if (uri == null ||
        !uri.isScheme('https') ||
        uri.host != 'github.com' ||
        !uri.path.startsWith(prefix)) {
      return null;
    }
    return uri;
  }

  /// ZIPを取得・検証し、`updater.exe` を起動して準備完了を待ちます。
  ///
  /// 戻ったら呼び出し側はアプリを終了します（updaterが置き換えと再起動を行います）。
  Future<void> install(
    AppUpdate update, {
    required void Function(double fraction) onProgress,
  }) async {
    final work = Directory(
      p.join(
        paths.updatesDirectory.path,
        'update-${update.version}-${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    await work.create(recursive: true);
    try {
      final expected = await _fetchChecksum(update);
      final archive = File(p.join(work.path, update.archiveName));
      final actual = await _download(update, archive, onProgress);
      if (actual != expected) {
        throw StateError('更新ファイルのSHA-256が一致しません');
      }
      // updater.exe 自身も置き換え対象のため、作業フォルダへ複製して起動します。
      final updater = await paths.updaterExecutable.copy(
        p.join(work.path, AppConfig.updaterExecutableName),
      );
      final ready = File(p.join(work.path, 'update-ready.txt'));
      await bridge.launchDetached(updater.path, <String>[
        '--parent-pid',
        '$pid',
        '--archive',
        archive.path,
        '--install-dir',
        paths.root,
        '--update-dir',
        work.path,
        '--ready-file',
        ready.path,
        '--data-dir-name',
        AppConfig.dataDirectoryName,
        '--exe-name',
        AppConfig.executableName,
        '--expected-root',
        AppConfig.releaseArchiveRootName,
        '--expected-version',
        '${update.version}',
        '--expected-sha256',
        expected,
      ]);
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!await ready.exists()) {
        final error = File(p.join(work.path, 'update-error.txt'));
        if (await error.exists()) {
          throw StateError('更新プログラムが失敗しました: ${await error.readAsString()}');
        }
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('更新プログラムが起動しませんでした');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } on Object {
      await work.delete(recursive: true).catchError((Object _) => work);
      rethrow;
    }
  }

  /// 前回の更新が失敗していれば理由を返し、古い作業フォルダを片付けます。
  Future<String?> takeLastFailure() async {
    final directory = paths.updatesDirectory;
    if (!await directory.exists()) return null;
    String? failure;
    DateTime? newest;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final error = File(p.join(entity.path, 'update-error.txt'));
      if (await error.exists()) {
        final modified = await error.lastModified();
        if (newest == null || modified.isAfter(newest)) {
          newest = modified;
          failure = utf8
              .decode(await error.readAsBytes(), allowMalformed: true)
              .replaceFirst('﻿', '')
              .trim();
        }
      }
      await entity.delete(recursive: true).catchError((Object _) => entity);
    }
    return failure;
  }

  void close() => _client.close(force: true);

  Future<String> _fetchChecksum(AppUpdate update) async {
    final response = await _get(update.checksumUri);
    _expectOk(response);
    final text = ascii.decode(
      await _readAll(response, limit: 4096),
      allowInvalid: true,
    );
    final match = RegExp(r'^\s*([0-9a-fA-F]{64})\b').firstMatch(text);
    if (match == null) throw const FormatException('チェックサムファイルの形式が不正です');
    return match.group(1)!.toLowerCase();
  }

  Future<String> _download(
    AppUpdate update,
    File destination,
    void Function(double fraction) onProgress,
  ) async {
    final response = await _get(update.archiveUri);
    _expectOk(response);
    if (response.contentLength >= 0 &&
        response.contentLength != update.archiveSize) {
      throw StateError('更新ファイルのサイズが一致しません');
    }
    final partial = File('${destination.path}.part');
    final sink = partial.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    var received = 0;
    try {
      await for (final chunk in response.timeout(readTimeout)) {
        received += chunk.length;
        if (received > update.archiveSize) {
          throw StateError('更新ファイルが宣言サイズを超えました');
        }
        sink.add(chunk);
        hasher.add(chunk);
        onProgress(received / update.archiveSize);
      }
    } finally {
      await sink.close();
    }
    if (received != update.archiveSize) {
      throw StateError('更新ファイルを最後まで取得できませんでした');
    }
    hasher.close();
    await partial.rename(destination.path);
    return digest.value.toString();
  }

  /// リダイレクトは自前で追い、行き先が許可したホストかを追う前に確かめます。
  Future<HttpClientResponse> _get(Uri uri, {String? accept}) async {
    var current = uri;
    for (var hop = 0; hop < 5; hop++) {
      if (!_allowedHost(current)) {
        throw StateError('許可されていない取得先です: ${current.host}');
      }
      final request = await _client.getUrl(current).timeout(readTimeout);
      request.followRedirects = false;
      if (accept != null) {
        request.headers
          ..set(HttpHeaders.acceptHeader, accept)
          ..set('X-GitHub-Api-Version', '2022-11-28');
      }
      final response = await request.close().timeout(readTimeout);
      if (!response.isRedirect) return response;
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null) throw StateError('リダイレクト先がありません');
      current = current.resolve(location);
      accept = null;
    }
    throw StateError('リダイレクトが多すぎます');
  }

  static bool _allowedHost(Uri uri) =>
      uri.isScheme('https') &&
      (uri.host == 'api.github.com' ||
          uri.host == 'github.com' ||
          uri.host.endsWith('.githubusercontent.com'));

  static void _expectOk(HttpClientResponse response) {
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}');
    }
  }

  static Future<Uint8List> _readAll(
    HttpClientResponse response, {
    required int limit,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(readTimeout)) {
      builder.add(chunk);
      if (builder.length > limit) throw const FormatException('応答が大きすぎます');
    }
    return builder.takeBytes();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
