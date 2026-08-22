// Project: DAM for Windows Tools
// File: app_settings.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

class AppSettings {
  const AppSettings({
    this.disableModuleCheck = true,
    this.disableForegroundCheck = true,
    this.replaceVideoUrls = true,
    this.scoringEnabled = true,
    this.skipEnabled = true,
    this.skipMs = 150,
  });

  static const int minimumSkipMs = 0;
  static const int maximumSkipMs = 30000;
  static const int defaultSkipMs = 150;

  final bool disableModuleCheck;
  final bool disableForegroundCheck;
  final bool replaceVideoUrls;
  final bool scoringEnabled;
  final bool skipEnabled;
  final int skipMs;

  int get normalizedSkipMs => skipMs.clamp(minimumSkipMs, maximumSkipMs);
  int get effectiveSkipMs => skipEnabled ? normalizedSkipMs : 0;

  AppSettings normalized() => copyWith(skipMs: normalizedSkipMs);

  AppSettings copyWith({
    bool? disableModuleCheck,
    bool? disableForegroundCheck,
    bool? replaceVideoUrls,
    bool? scoringEnabled,
    bool? skipEnabled,
    int? skipMs,
  }) {
    return AppSettings(
      disableModuleCheck: disableModuleCheck ?? this.disableModuleCheck,
      disableForegroundCheck:
          disableForegroundCheck ?? this.disableForegroundCheck,
      replaceVideoUrls: replaceVideoUrls ?? this.replaceVideoUrls,
      scoringEnabled: scoringEnabled ?? this.scoringEnabled,
      skipEnabled: skipEnabled ?? this.skipEnabled,
      skipMs: skipMs ?? this.skipMs,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'disableModuleCheck': disableModuleCheck,
    'disableForegroundCheck': disableForegroundCheck,
    'replaceVideoUrls': replaceVideoUrls,
    'scoringEnabled': scoringEnabled,
    'skipEnabled': skipEnabled,
    'skipMs': normalizedSkipMs,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final rawSkip = json['skipMs'];
    return AppSettings(
      disableModuleCheck: json['disableModuleCheck'] as bool? ?? true,
      disableForegroundCheck: json['disableForegroundCheck'] as bool? ?? true,
      replaceVideoUrls: json['replaceVideoUrls'] as bool? ?? true,
      scoringEnabled: json['scoringEnabled'] as bool? ?? true,
      skipEnabled: json['skipEnabled'] as bool? ?? true,
      skipMs: rawSkip is num
          ? rawSkip.toInt().clamp(minimumSkipMs, maximumSkipMs)
          : defaultSkipMs,
    );
  }
}
