import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 上流HLSマニフェスト内のURLを、ローカル中継URLへ書き換えます。
///
/// 書き換えたURLは `register` で中継先として登録され、中継IDは元URLの
/// SHA-256先頭32桁です。上流URLやトークンは保存しません。
String rewriteManifest({
  required String source,
  required Uri baseUri,
  required String proxyPrefix,
  required void Function(String id, Uri target) register,
}) {
  String localize(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.length > 8192) return raw;
    final Uri resolved;
    try {
      resolved = baseUri.resolve(trimmed);
    } on FormatException {
      return raw;
    }
    if (!resolved.isScheme('http') && !resolved.isScheme('https')) return raw;
    final id = sha256
        .convert(utf8.encode(resolved.toString()))
        .toString()
        .substring(0, 32);
    register(id, resolved);
    return '$proxyPrefix$id';
  }

  final uriAttribute = RegExp(r'URI="([^"]+)"');
  return source
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((line) {
        if (line.isEmpty) return line;
        if (!line.startsWith('#')) return localize(line);
        return line.replaceAllMapped(
          uriAttribute,
          (match) => 'URI="${localize(match.group(1)!)}"',
        );
      })
      .join('\n');
}
