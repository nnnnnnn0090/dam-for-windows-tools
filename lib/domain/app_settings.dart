// Project: DAM for Windows Tools
// File: app_settings.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

/// GUIと実行サービスが共有する、利用者が変更可能な動作設定を表します。
///
/// 保存データが古い場合や範囲外の値を含む場合でも、安全な既定値へ戻せる
/// ように、正規化と復元の責務をこの型へ集約しています。
class AppSettings {
  /// 初回起動時の設定を含む設定値を生成します。
  ///
  /// 機能は明示的に無効化されるまで有効とし、遅延補正は150ミリ秒から
  /// 開始します。
  const AppSettings({
    this.disableModuleCheck = true,
    this.disableForegroundCheck = true,
    this.replaceVideoUrls = true,
    this.scoringOverlayEnabled = true,
    this.scoringShowZeroTechniques = true,
    this.skipEnabled = true,
    this.skipMs = 150,
  });

  static const int minimumSkipMs = 0;
  static const int maximumSkipMs = 30000;
  static const int defaultSkipMs = 150;

  final bool disableModuleCheck;
  final bool disableForegroundCheck;
  final bool replaceVideoUrls;
  final bool scoringOverlayEnabled;
  final bool scoringShowZeroTechniques;
  final bool skipEnabled;
  final int skipMs;

  /// 入力元に関係なく、遅延補正値をDAMで扱える範囲へ収めます。
  int get normalizedSkipMs => skipMs.clamp(minimumSkipMs, maximumSkipMs);

  /// 遅延補正が無効なときは、保存値を変更せず実行時だけ0として扱います。
  int get effectiveSkipMs => skipEnabled ? normalizedSkipMs : 0;

  /// 現在の設定を、永続化やサービス適用に安全な値へ正規化します。
  AppSettings normalized() => copyWith(skipMs: normalizedSkipMs);

  /// 指定された項目だけを差し替えた新しい設定を返します。
  ///
  /// 設定更新を不変オブジェクトとして扱い、GUIと実行中サービスの間で
  /// 途中状態が共有されないようにします。
  AppSettings copyWith({
    bool? disableModuleCheck,
    bool? disableForegroundCheck,
    bool? replaceVideoUrls,
    bool? scoringOverlayEnabled,
    bool? scoringShowZeroTechniques,
    bool? skipEnabled,
    int? skipMs,
  }) {
    return AppSettings(
      disableModuleCheck: disableModuleCheck ?? this.disableModuleCheck,
      disableForegroundCheck:
          disableForegroundCheck ?? this.disableForegroundCheck,
      replaceVideoUrls: replaceVideoUrls ?? this.replaceVideoUrls,
      scoringOverlayEnabled:
          scoringOverlayEnabled ?? this.scoringOverlayEnabled,
      scoringShowZeroTechniques:
          scoringShowZeroTechniques ?? this.scoringShowZeroTechniques,
      skipEnabled: skipEnabled ?? this.skipEnabled,
      skipMs: skipMs ?? this.skipMs,
    );
  }

  /// 次回起動時にも必要な設定項目だけをJSON形式へ変換します。
  Map<String, Object> toJson() => <String, Object>{
    'disableModuleCheck': disableModuleCheck,
    'disableForegroundCheck': disableForegroundCheck,
    'replaceVideoUrls': replaceVideoUrls,
    'scoringOverlayEnabled': scoringOverlayEnabled,
    'scoringShowZeroTechniques': scoringShowZeroTechniques,
    'skipEnabled': skipEnabled,
    'skipMs': normalizedSkipMs,
  };

  /// 保存済みJSONから設定を復元し、欠損値と不正な補正値を安全に補います。
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final rawSkip = json['skipMs'];
    return AppSettings(
      disableModuleCheck: json['disableModuleCheck'] as bool? ?? true,
      disableForegroundCheck: json['disableForegroundCheck'] as bool? ?? true,
      replaceVideoUrls: json['replaceVideoUrls'] as bool? ?? true,
      scoringOverlayEnabled:
          json['scoringOverlayEnabled'] as bool? ??
          json['scoringEnabled'] as bool? ??
          true,
      scoringShowZeroTechniques:
          json['scoringShowZeroTechniques'] as bool? ?? true,
      skipEnabled: json['skipEnabled'] as bool? ?? true,
      skipMs: rawSkip is num
          ? rawSkip.toInt().clamp(minimumSkipMs, maximumSkipMs)
          : defaultSkipMs,
    );
  }
}
