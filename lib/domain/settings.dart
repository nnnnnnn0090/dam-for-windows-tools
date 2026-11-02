/// 利用者が変更できる動作設定です。不変で、保存・送信前に必ず正規化されます。
class AppSettings {
  const AppSettings({
    this.disableModuleCheck = true,
    this.disableForegroundCheck = true,
    this.replaceVideoUrls = true,
    this.scoringOverlayEnabled = true,
    this.scoringShowZeroTechniques = true,
    this.skipEnabled = true,
    this.skipMs = defaultSkipMs,
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

  /// 遅延補正が無効なときは、保存値を残したまま実行時だけ0として扱います。
  int get effectiveSkipMs => skipEnabled ? skipMs : 0;

  AppSettings copyWith({
    bool? disableModuleCheck,
    bool? disableForegroundCheck,
    bool? replaceVideoUrls,
    bool? scoringOverlayEnabled,
    bool? scoringShowZeroTechniques,
    bool? skipEnabled,
    int? skipMs,
  }) => AppSettings(
    disableModuleCheck: disableModuleCheck ?? this.disableModuleCheck,
    disableForegroundCheck:
        disableForegroundCheck ?? this.disableForegroundCheck,
    replaceVideoUrls: replaceVideoUrls ?? this.replaceVideoUrls,
    scoringOverlayEnabled: scoringOverlayEnabled ?? this.scoringOverlayEnabled,
    scoringShowZeroTechniques:
        scoringShowZeroTechniques ?? this.scoringShowZeroTechniques,
    skipEnabled: skipEnabled ?? this.skipEnabled,
    skipMs: (skipMs ?? this.skipMs).clamp(minimumSkipMs, maximumSkipMs),
  );

  /// 保存形式はv1と同一で、v1の設定ファイルをそのまま引き継げます。
  Map<String, Object> toJson() => <String, Object>{
    'disableModuleCheck': disableModuleCheck,
    'disableForegroundCheck': disableForegroundCheck,
    'replaceVideoUrls': replaceVideoUrls,
    'scoringOverlayEnabled': scoringOverlayEnabled,
    'scoringShowZeroTechniques': scoringShowZeroTechniques,
    'skipEnabled': skipEnabled,
    'skipMs': skipMs.clamp(minimumSkipMs, maximumSkipMs),
  };

  /// 接続ヘルパーへ送る機能設定です。遅延補正はアプリ内だけで扱います。
  Map<String, Object> toHelperConfig() => <String, Object>{
    'disableModuleCheck': disableModuleCheck,
    'disableForegroundCheck': disableForegroundCheck,
    'replaceVideoUrls': replaceVideoUrls,
    'scoringOverlayEnabled': scoringOverlayEnabled,
    'scoringShowZeroTechniques': scoringShowZeroTechniques,
  };

  /// 欠損・型違いは既定値で補います。旧キー `scoringEnabled` も読み込みます。
  factory AppSettings.fromJson(Map<String, Object?> json) {
    bool flag(String key, [String? legacyKey]) {
      final value = json[key] ?? (legacyKey == null ? null : json[legacyKey]);
      return value is bool ? value : true;
    }

    final rawSkip = json['skipMs'];
    return AppSettings(
      disableModuleCheck: flag('disableModuleCheck'),
      disableForegroundCheck: flag('disableForegroundCheck'),
      replaceVideoUrls: flag('replaceVideoUrls'),
      scoringOverlayEnabled: flag('scoringOverlayEnabled', 'scoringEnabled'),
      scoringShowZeroTechniques: flag('scoringShowZeroTechniques'),
      skipEnabled: flag('skipEnabled'),
      skipMs: rawSkip is num
          ? rawSkip.toInt().clamp(minimumSkipMs, maximumSkipMs)
          : defaultSkipMs,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.disableModuleCheck == disableModuleCheck &&
      other.disableForegroundCheck == disableForegroundCheck &&
      other.replaceVideoUrls == replaceVideoUrls &&
      other.scoringOverlayEnabled == scoringOverlayEnabled &&
      other.scoringShowZeroTechniques == scoringShowZeroTechniques &&
      other.skipEnabled == skipEnabled &&
      other.skipMs == skipMs;

  @override
  int get hashCode => Object.hash(
    disableModuleCheck,
    disableForegroundCheck,
    replaceVideoUrls,
    scoringOverlayEnabled,
    scoringShowZeroTechniques,
    skipEnabled,
    skipMs,
  );
}
