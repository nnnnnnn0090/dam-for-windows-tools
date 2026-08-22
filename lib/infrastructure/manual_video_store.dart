// Project: DAM for Windows Tools
// File: manual_video_store.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../domain/models.dart';
import 'app_paths.dart';
import 'atomic_file.dart';

class ManualVideoStore {
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
          // A failed import is ignored if another process still owns it.
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

  Future<void> remove(String rawVideoId) async {
    final videoId = normalizeVideoAssetId(rawVideoId);
    if (videoId.isEmpty) return;
    await _removeOtherFiles(videoId);
  }

  Future<void> _removeOtherFiles(String videoId, {File? keep}) async {
    final directory = paths.manualVideosDirectory;
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || _videoIdFor(entity) != videoId) continue;
      if (keep != null && p.equals(entity.path, keep.path)) continue;
      await entity.delete();
    }
  }

  static String _videoIdFor(File file) {
    final extension = p
        .extension(file.path)
        .toLowerCase()
        .replaceFirst('.', '');
    if (!_supportedExtensionSet.contains(extension)) return '';
    return normalizeVideoAssetId(p.basenameWithoutExtension(file.path));
  }

  static String _randomToken(int bytes) {
    final random = Random.secure();
    return List<int>.generate(
      bytes,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}
