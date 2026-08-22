// Project: DAM for Windows Tools
// File: release_update_service.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
import '../domain/app_update.dart';
import 'app_paths.dart';

/// GitHub Releasesの確認、配布ZIPの検証、Windows更新処理の起動を担当します。
///
/// 更新対象は公式リポジトリの固定名アセットだけに限定し、ZIPの外部SHA-256と
/// GitHub APIのdigestが提供される場合はそれも一致したときだけ、終了後の置換処理へ進みます。
class ReleaseUpdateService {
  /// アプリの管理パスと専用HTTPクライアントを受け取ります。
  ReleaseUpdateService({required this.paths, HttpClient? client})
    : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 15);
    _client.idleTimeout = const Duration(seconds: 15);
    _client.autoUncompress = true;
  }

  static const int _maximumReleaseResponseBytes = 1024 * 1024;
  static const int _maximumChecksumBytes = 4096;
  static const int _maximumArchiveBytes = 512 * 1024 * 1024;
  static const String _repositoryPath = '/nnnnnnn0090/dam-for-windows-tools/';

  final AppPaths paths;
  final HttpClient _client;

  /// 配布フォルダとして必要なEXEとruntimeが揃い、自己更新できる状態か返します。
  bool get isSupported => Platform.isWindows && paths.isPackagedApplication;

  /// GitHubの最新公開リリースを取得し、現在版より新しい場合だけ返します。
  Future<AppUpdate?> checkForUpdate() async {
    final response = await _getBytes(
      Uri.parse(AppConfig.latestReleaseApi),
      maximumBytes: _maximumReleaseResponseBytes,
      allowNotFound: true,
    );
    if (response == null) return null;
    final decoded = jsonDecode(utf8.decode(response));
    if (decoded is! Map) {
      throw const FormatException('更新情報の形式が正しくありません');
    }
    return parseLatestRelease(
      Map<String, dynamic>.from(decoded),
      currentVersion: AppConfig.productVersion,
    );
  }

  /// 更新ZIPとチェックサムを取得・検証し、親終了を待つ更新スクリプトを起動します。
  Future<void> downloadAndLaunch(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    if (!isSupported) {
      throw StateError('配布フォルダから起動した場合だけ自動更新できます');
    }
    final updateRoot = await _createUpdateDirectory(update.version);
    final checksumText = utf8.decode(
      (await _getBytes(
        update.checksumUri,
        maximumBytes: _maximumChecksumBytes,
      ))!,
    );
    final expectedHash = _readArchiveChecksum(checksumText, update.archiveName);
    final apiDigest = update.apiDigest;
    if (apiDigest != null && apiDigest != expectedHash) {
      throw StateError('GitHubのdigestとチェックサムファイルが一致しません');
    }

    final archive = File(p.join(updateRoot.path, update.archiveName));
    await _downloadArchive(update, archive, onProgress: onProgress);
    final actualHash = (await sha256.bind(archive.openRead()).first).toString();
    if (actualHash != expectedHash) {
      try {
        await archive.delete();
      } on FileSystemException {
        // 不正ZIPの削除失敗は更新を中断する主原因を上書きしないようにします。
      }
      throw StateError('更新ZIPのSHA-256が一致しません');
    }
    onProgress?.call(1);

    final script = File(p.join(updateRoot.path, 'update.ps1'));
    await script.writeAsString(
      await rootBundle.loadString(AppConfig.updaterScriptAsset),
      flush: true,
    );
    await _launchUpdater(
      update: update,
      updateRoot: updateRoot,
      archive: archive,
      script: script,
      expectedHash: expectedHash,
    );
  }

  /// 前回の更新処理が残した失敗内容を1件だけ読み取り、診断表示後の重複を防ぎます。
  Future<String?> takeLastFailure() async {
    final root = _updatesRoot;
    if (!await root.exists()) return null;
    final errors = <File>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final error = File(p.join(entity.path, 'update-error.txt'));
      if (await error.exists()) errors.add(error);
    }
    String? failure;
    if (errors.isNotEmpty) {
      errors.sort(
        (left, right) =>
            right.lastModifiedSync().compareTo(left.lastModifiedSync()),
      );
      final selected = errors.first;
      final text = await selected.readAsString();
      try {
        await selected.delete();
      } on FileSystemException {
        // 読み取れた失敗内容は返し、削除できない場合だけ次回も診断へ残します。
      }
      failure = text.length <= 4000
          ? text.trim()
          : text.substring(0, 4000).trim();
    }
    await _cleanupOldUpdateDirectories(root);
    return failure;
  }

  /// 更新確認に使ったKeep-Alive接続を閉じ、アプリ終了を妨げないようにします。
  void close() => _client.close(force: true);

  /// GitHub最新リリースJSONから、固定名の実行ZIPとSHA-256だけを選択します。
  @visibleForTesting
  static AppUpdate? parseLatestRelease(
    Map<String, dynamic> release, {
    required String currentVersion,
  }) {
    if (release['draft'] == true || release['prerelease'] == true) return null;
    final current = AppVersion.tryParse(currentVersion);
    final latest = AppVersion.tryParse(release['tag_name']?.toString() ?? '');
    if (current == null || latest == null) {
      throw const FormatException('リリースのバージョン形式が正しくありません');
    }
    if (latest.compareTo(current) <= 0) return null;

    final archiveName =
        '${AppConfig.releaseArchiveRootName}-$latest-win-x64.zip';
    final checksumName = '$archiveName.sha256';
    final assets = release['assets'];
    if (assets is! List) {
      throw const FormatException('リリースに配布ファイル一覧がありません');
    }
    Map<String, dynamic>? archiveAsset;
    Map<String, dynamic>? checksumAsset;
    for (final rawAsset in assets) {
      if (rawAsset is! Map) continue;
      final asset = Map<String, dynamic>.from(rawAsset);
      if (asset['state'] != null && asset['state'] != 'uploaded') continue;
      if (asset['name'] == archiveName) archiveAsset = asset;
      if (asset['name'] == checksumName) checksumAsset = asset;
    }
    if (archiveAsset == null || checksumAsset == null) {
      throw FormatException('$latest用のWindows更新ファイルがありません');
    }

    final archiveUri = _validatedReleaseAssetUri(archiveAsset);
    final checksumUri = _validatedReleaseAssetUri(checksumAsset);
    final archiveSize = archiveAsset['size'];
    if (archiveSize is! int ||
        archiveSize <= 0 ||
        archiveSize > _maximumArchiveBytes) {
      throw const FormatException('更新ZIPのサイズが許可範囲外です');
    }
    final rawDigest = archiveAsset['digest']?.toString().toLowerCase();
    final apiDigest =
        rawDigest != null &&
            RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(rawDigest)
        ? rawDigest.substring(7)
        : null;
    final pageUri = Uri.tryParse(release['html_url']?.toString() ?? '');
    final safePageUri =
        pageUri != null &&
            pageUri.scheme == 'https' &&
            pageUri.host.toLowerCase() == 'github.com'
        ? pageUri
        : Uri.parse(
            'https://github.com/nnnnnnn0090/dam-for-windows-tools/releases',
          );
    final rawNotes = release['body']?.toString().trim() ?? '';
    return AppUpdate(
      version: latest,
      archiveUri: archiveUri,
      checksumUri: checksumUri,
      archiveName: archiveName,
      archiveSize: archiveSize,
      releasePageUri: safePageUri,
      notes: rawNotes.length <= 4000 ? rawNotes : rawNotes.substring(0, 4000),
      apiDigest: apiDigest,
    );
  }

  /// APIアセットから公式リポジトリ配下のHTTPSダウンロードURLだけを返します。
  static Uri _validatedReleaseAssetUri(Map<String, dynamic> asset) {
    final uri = Uri.tryParse(asset['browser_download_url']?.toString() ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.toLowerCase() != 'github.com' ||
        !uri.path.toLowerCase().startsWith(
          '${_repositoryPath}releases/download/',
        )) {
      throw const FormatException('更新ファイルの取得先が正しくありません');
    }
    return uri;
  }

  /// SHA-256ファイルから対象ZIPと完全一致する1行だけを読み取ります。
  static String _readArchiveChecksum(String text, String archiveName) {
    final escapedName = RegExp.escape(archiveName);
    final match = RegExp(
      '^([0-9a-fA-F]{64})  $escapedName\\s*\$',
      multiLine: true,
    ).firstMatch(text.replaceAll('\r\n', '\n'));
    if (match == null) {
      throw const FormatException('更新ZIPのSHA-256を取得できません');
    }
    return match.group(1)!.toLowerCase();
  }

  /// 更新ごとの一時ディレクトリをデータフォルダ内へ安全に作成します。
  Future<Directory> _createUpdateDirectory(AppVersion version) async {
    final root = _updatesRoot;
    await root.create(recursive: true);
    await _cleanupOldUpdateDirectories(root);
    final directory = Directory(
      p.join(
        root.path,
        'update-$version-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await directory.create();
    return directory;
  }

  /// 24時間以上前の完了済み更新作業だけを削除し、直近の失敗情報は保持します。
  Future<void> _cleanupOldUpdateDirectories(Directory root) async {
    final threshold = DateTime.now().subtract(const Duration(hours: 24));
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      try {
        if ((await entity.stat()).modified.isBefore(threshold)) {
          await entity.delete(recursive: true);
        }
      } on FileSystemException {
        // 更新プロセスが使用中のディレクトリは次回起動時に再試行します。
      }
    }
  }

  /// ZIP本体を一時ファイルへ保存し、API記載サイズと上限を同時に検証します。
  Future<void> _downloadArchive(
    AppUpdate update,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    final temporary = File('${destination.path}.part');
    final response = await _openGet(update.archiveUri);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        '更新ZIPを取得できませんでした (${response.statusCode})',
        uri: update.archiveUri,
      );
    }
    if (response.contentLength > _maximumArchiveBytes) {
      await response.drain<void>();
      throw StateError('更新ZIPが許可サイズを超えています');
    }
    var received = 0;
    final sink = temporary.openWrite();
    try {
      await for (final chunk in response) {
        received += chunk.length;
        if (received > _maximumArchiveBytes) {
          throw StateError('更新ZIPが許可サイズを超えています');
        }
        sink.add(chunk);
        onProgress?.call((received / update.archiveSize).clamp(0, 0.99));
      }
      await sink.close();
      if (received != update.archiveSize) {
        throw StateError('更新ZIPのサイズがGitHubの情報と一致しません');
      }
      await temporary.rename(destination.path);
    } on Object {
      await sink.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  /// 小さなJSONまたはチェックサム応答を上限付きでメモリへ読み込みます。
  Future<List<int>?> _getBytes(
    Uri uri, {
    required int maximumBytes,
    bool allowNotFound = false,
  }) async {
    final response = await _openGet(uri);
    if (allowNotFound && response.statusCode == HttpStatus.notFound) {
      await response.drain<void>();
      return null;
    }
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        '更新サーバーがエラーを返しました (${response.statusCode})',
        uri: uri,
      );
    }
    if (response.contentLength > maximumBytes) {
      await response.drain<void>();
      throw StateError('更新サーバーの応答が許可サイズを超えています');
    }
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response) {
      length += chunk.length;
      if (length > maximumBytes) {
        throw StateError('更新サーバーの応答が許可サイズを超えています');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// GitHub APIと公式アセットだけへ、製品識別ヘッダー付きGETを送ります。
  Future<HttpClientResponse> _openGet(Uri uri) async {
    final request = await _client.getUrl(uri);
    request
      ..followRedirects = true
      ..maxRedirects = 5
      ..headers.set(
        HttpHeaders.userAgentHeader,
        '${AppConfig.releaseArchiveRootName}/${AppConfig.productVersion}',
      )
      ..headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..headers.set('X-GitHub-Api-Version', '2022-11-28');
    final response = await request.close();
    for (final redirect in response.redirects) {
      if (!_isAllowedRedirect(redirect.location)) {
        await response.drain<void>();
        throw StateError('更新ファイルが許可されていない取得先へ転送されました');
      }
    }
    return response;
  }

  /// GitHubが配布アセットに使うHTTPSホストだけをリダイレクト先に許可します。
  static bool _isAllowedRedirect(Uri uri) {
    if (uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    return host == 'github.com' ||
        host == 'objects.githubusercontent.com' ||
        host == 'release-assets.githubusercontent.com' ||
        host.endsWith('.githubusercontent.com');
  }

  /// Windows標準PowerShellを絶対パスで起動し、親終了後の置換処理へ引き継ぎます。
  Future<void> _launchUpdater({
    required AppUpdate update,
    required Directory updateRoot,
    required File archive,
    required File script,
    required String expectedHash,
  }) async {
    final windowsRoot = Platform.environment['SystemRoot'];
    if (windowsRoot == null || windowsRoot.trim().isEmpty) {
      throw StateError('Windowsシステムディレクトリを取得できません');
    }
    final powershell = File(
      p.join(
        windowsRoot,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      ),
    );
    if (!await powershell.exists()) {
      throw StateError('Windows PowerShellが見つかりません');
    }
    await Process.start(
      powershell.path,
      <String>[
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-ParentProcessId',
        pid.toString(),
        '-ArchivePath',
        archive.path,
        '-ExpectedArchiveSha256',
        expectedHash,
        '-InstallDirectory',
        paths.applicationDirectory.path,
        '-UpdateDirectory',
        updateRoot.path,
        '-DataDirectoryName',
        AppConfig.dataDirectoryName,
        '-ExecutableName',
        AppConfig.executableName,
        '-ExpectedRootName',
        AppConfig.releaseArchiveRootName,
        '-ExpectedVersion',
        update.version.toString(),
      ],
      mode: ProcessStartMode.detached,
      workingDirectory: paths.applicationDirectory.path,
    );
  }

  /// 更新用一時データを、永続データフォルダ内の専用領域へまとめます。
  Directory get _updatesRoot =>
      Directory(p.join(paths.supportDirectory.path, 'updates'));
}
