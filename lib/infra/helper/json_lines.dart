import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// バイト列を改行区切りのJSONオブジェクトへ変換します。
///
/// 1行が [maximumLineBytes] を超えた時点でその行を捨て、改行まで読み飛ばします。
/// 行を最後まで組み立ててから判定する方式と違い、巨大な行でメモリを使い切りません。
class JsonLinesDecoder extends StreamTransformerBase<List<int>, JsonLinesItem> {
  const JsonLinesDecoder({required this.maximumLineBytes});

  final int maximumLineBytes;

  @override
  Stream<JsonLinesItem> bind(Stream<List<int>> stream) async* {
    final line = BytesBuilder(copy: false);
    var discarding = false;
    await for (final chunk in stream) {
      var start = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != 0x0a) continue;
        if (!discarding) {
          line.add(chunk.sublist(start, i));
          yield _decode(line.takeBytes());
        } else {
          discarding = false;
          line.clear();
        }
        start = i + 1;
      }
      if (start < chunk.length && !discarding) {
        line.add(chunk.sublist(start));
        if (line.length > maximumLineBytes) {
          discarding = true;
          line.clear();
          yield const JsonLinesItem.error('上限を超える長さの行を破棄しました');
        }
      }
    }
    if (!discarding && line.isNotEmpty) yield _decode(line.takeBytes());
  }

  JsonLinesItem _decode(Uint8List bytes) {
    if (bytes.length > maximumLineBytes) {
      return const JsonLinesItem.error('上限を超える長さの行を破棄しました');
    }
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    if (text.isEmpty) return const JsonLinesItem.skip();
    try {
      final value = jsonDecode(text);
      if (value is Map<String, Object?>) return JsonLinesItem.value(value);
    } on FormatException {
      // 下の共通エラーへ。
    }
    return const JsonLinesItem.error('JSONオブジェクトではない行を破棄しました');
  }
}

/// [JsonLinesDecoder] の出力1件です。値・エラー・空行のいずれかです。
class JsonLinesItem {
  const JsonLinesItem.value(Map<String, Object?> this.value) : error = null;
  const JsonLinesItem.error(String this.error) : value = null;
  const JsonLinesItem.skip() : value = null, error = null;

  final Map<String, Object?>? value;
  final String? error;
}
