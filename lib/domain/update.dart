/// 数値3要素だけを受け入れるアプリバージョンです。
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static final RegExp _pattern = RegExp(r'^v?(\d{1,6})\.(\d{1,6})\.(\d{1,6})$');

  /// `v1.2.3` または `1.2.3` を解析します。
  static AppVersion? tryParse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) return null;
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// GitHub Releasesから選んだWindows向け更新です。
class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.archiveUri,
    required this.archiveName,
    required this.archiveSize,
    required this.checksumUri,
    required this.notes,
  });

  final AppVersion version;
  final Uri archiveUri;
  final String archiveName;
  final int archiveSize;

  /// ZIPと同時に公開される `<zip>.sha256` です。検証できない更新は適用しません。
  final Uri checksumUri;
  final String notes;
}
