// Project: DAM for Windows Tools
// File: app_update.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

/// 数値3要素だけを受け入れ、リリースの新旧判定に使うアプリバージョンです。
class AppVersion implements Comparable<AppVersion> {
  /// メジャー・マイナー・パッチ番号を保持する不変値を生成します。
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  /// `v1.2.3`または`1.2.3`を解析し、それ以外のタグは拒否します。
  static AppVersion? tryParse(String value) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(value.trim());
    if (match == null) return null;
    final parts = <int>[
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
    if (parts.any((part) => part > 999999)) return null;
    return AppVersion(parts[0], parts[1], parts[2]);
  }

  /// メジャー、マイナー、パッチの順に数値比較します。
  @override
  int compareTo(AppVersion other) {
    final majorOrder = major.compareTo(other.major);
    if (majorOrder != 0) return majorOrder;
    final minorOrder = minor.compareTo(other.minor);
    if (minorOrder != 0) return minorOrder;
    return patch.compareTo(other.patch);
  }

  /// 3要素をリリース表示用の文字列へ戻します。
  @override
  String toString() => '$major.$minor.$patch';

  /// 同じ3要素を持つ値だけを等価と判定します。
  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch;

  /// バージョン3要素から安定したハッシュ値を生成します。
  @override
  int get hashCode => Object.hash(major, minor, patch);
}

/// GitHub Releasesから検証済み名称で選択したWindows更新情報です。
class AppUpdate {
  /// バージョン、配布ZIP、チェックサム、表示用リリース情報を保持します。
  const AppUpdate({
    required this.version,
    required this.archiveUri,
    required this.checksumUri,
    required this.archiveName,
    required this.archiveSize,
    required this.releasePageUri,
    required this.notes,
    this.apiDigest,
  });

  final AppVersion version;
  final Uri archiveUri;
  final Uri checksumUri;
  final String archiveName;
  final int archiveSize;
  final Uri releasePageUri;
  final String notes;
  final String? apiDigest;
}

/// GUIが更新確認・取得・再起動のどの段階にあるかを表します。
enum AppUpdatePhase {
  idle,
  checking,
  available,
  downloading,
  restarting,
  latest,
  failed,
}
