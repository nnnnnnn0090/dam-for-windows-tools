// Project: DAM for Windows Tools
// File: manual_video_store.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../domain/value_objects.dart';
import 'app_paths.dart';
import 'atomic_file.dart';

/// 差し替え動画をEXE横の管理領域へコピーし、動画ID単位で管理します。
///
/// 元ファイルへの参照だけを保存しないため、配布フォルダごと別PCへ移動しても
/// 登録済み動画を再利用できます。
class ManualVideoStore {
  /// アプリ管理ディレクトリを持つ動画ストアを生成します。
  ManualVideoStore(this.paths);

  static const List<String> supportedExtensions = <String>[
    'mp4',
    'mkv',
    'mov',
    'avi',
    'webm',
    'm2ts',
    'ts',
  ];
  static final Set<String> _supportedExtensionSet = supportedExtensions.toSet();

  final AppPaths paths;

  /// 管理領域を走査し、各動画IDで最新の有効ファイルだけを復元します。
  ///
  /// 以前の失敗で残った取り込み中ファイルは、使用中でなければ削除します。
  Future<Map<String, File>> load() async {
    final directory = paths.manualVideosDirectory;
    await directory.create(recursive: true);
    final candidates = <String, List<File>>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      if (p.extension(entity.path).toLowerCase() == '.importing') {
        try {
          await entity.delete();
        } on FileSystemException {
          // 別プロセスがまだ保持している取り込み失敗ファイルは、次回走査へ残します。
        }
        continue;
      }
      final videoId = _videoIdFor(entity);
      if (videoId.isEmpty) continue;
      candidates.putIfAbsent(videoId, () => <File>[]).add(entity);
    }

    final result = <String, File>{};
    for (final entry in candidates.entries) {
      final files = entry.value;
      files.sort((left, right) {
        final modified = right.lastModifiedSync().compareTo(
          left.lastModifiedSync(),
        );
        return modified != 0 ? modified : left.path.compareTo(right.path);
      });
      result[entry.key] = files.first;
    }
    return result;
  }

  /// 選択動画を検証・コピーし、同じIDの旧形式ファイルを取り除きます。
  ///
  /// コピーサイズを確認してから原子的に確定するため、途中ファイルを再生しません。
  Future<File> import(String rawVideoId, File source) async {
    final videoId = normalizeVideoAssetId(rawVideoId);
    if (videoId.isEmpty) throw ArgumentError('動画IDが不正です');
    if (!await source.exists()) throw ArgumentError('選択した動画を読み込めません');
    if (await source.length() <= 0) throw ArgumentError('空の動画は指定できません');

    final extension = p
        .extension(source.path)
        .toLowerCase()
        .replaceFirst('.', '');
    if (!_supportedExtensionSet.contains(extension)) {
      throw ArgumentError('対応していない動画形式です');
    }
    final directory = paths.manualVideosDirectory;
    await directory.create(recursive: true);
    final destination = File(p.join(directory.path, '$videoId.$extension'));
    if (!p.equals(p.absolute(source.path), p.absolute(destination.path))) {
      final temporary = File(
        p.join(directory.path, '$videoId.${_randomToken(8)}.importing'),
      );
      try {
        await source.copy(temporary.path);
        if (await temporary.length() != await source.length()) {
          throw const FileSystemException('動画のコピー結果を検証できませんでした');
        }
        await replaceFileAtomically(temporary, destination);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
    await _removeOtherFiles(videoId, keep: destination);
    return destination;
  }

  /// 指定動画IDに一致する、アプリ管理領域内の動画だけを削除します。
  Future<void> remove(String rawVideoId) async {
    final videoId = normalizeVideoAssetId(rawVideoId);
    if (videoId.isEmpty) return;
    await _removeOtherFiles(videoId);
  }

  /// 指定IDの旧ファイルを列挙し、残すよう指定された1件以外を削除します。
  Future<void> _removeOtherFiles(String videoId, {File? keep}) async {
    final directory = paths.manualVideosDirectory;
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || _videoIdFor(entity) != videoId) continue;
      if (keep != null && p.equals(entity.path, keep.path)) continue;
      await entity.delete();
    }
  }

  /// 対応拡張子を持つファイル名から公開動画IDを復元します。
  static String _videoIdFor(File file) {
    final extension = p
        .extension(file.path)
        .toLowerCase()
        .replaceFirst('.', '');
    if (!_supportedExtensionSet.contains(extension)) return '';
    return normalizeVideoAssetId(p.basenameWithoutExtension(file.path));
  }

  /// 取り込み途中ファイルの衝突を防ぐ、暗号学的乱数名を生成します。
  static String _randomToken(int bytes) {
    final random = Random.secure();
    return List<int>.generate(
      bytes,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}
