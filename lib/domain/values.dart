final RegExp _videoAssetIdPattern = RegExp(r'^[0-9A-Za-z]+-[0-9A-Za-z_-]+$');
final RegExp _controlCharacters = RegExp(r'[\x00-\x1f\x7f]');
final RegExp _whitespaceRun = RegExp(r'\s+');

/// DAMのキー変更で指定できる範囲です。
const int minimumKey = -7;
const int maximumKey = 7;

/// 外部入力を「6184-92」形式の公開動画IDに限定し、それ以外は空文字列にします。
String normalizeVideoAssetId(Object? value) {
  if (value is! String) return '';
  final text = value.trim();
  return text.length <= 128 && _videoAssetIdPattern.hasMatch(text) ? text : '';
}

/// 外部由来の表示文字列から制御文字と余分な空白を除き、長さを制限します。
///
/// 切り詰めはコードポイント単位で行い、サロゲートペアを分断しません。
String sanitizeText(Object? value, {required int maximumLength}) {
  if (value is! String) return '';
  final cleaned = value
      .replaceAll(_controlCharacters, ' ')
      .replaceAll(_whitespaceRun, ' ')
      .trim();
  final runes = cleaned.runes;
  if (runes.length <= maximumLength) return cleaned;
  return String.fromCharCodes(runes.take(maximumLength)).trimRight();
}

/// 長さ制限内でホスト名を持つHTTP(S) URLだけを受け入れます。
Uri? parseHttpUri(Object? value, {int maximumLength = 8192}) {
  if (value is! String || value.length > maximumLength) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.isScheme('http') && !uri.isScheme('https')) {
    return null;
  }
  return uri.host.isEmpty ? null : uri;
}

/// 数値でない値を `fallback` とし、数値は `minimum`〜`maximum` に収めます。
int clampedInt(Object? value, int minimum, int maximum, {int fallback = 0}) =>
    value is num ? value.toInt().clamp(minimum, maximum) : fallback;

/// JSONのオブジェクトだけを `Map<String, Object?>` として取り出します。
Map<String, Object?>? jsonObject(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;
