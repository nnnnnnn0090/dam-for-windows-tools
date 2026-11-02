import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// 1つのJSONファイルを、破損に強い方法で読み書きします。
///
/// - 書き込みはインスタンスごとに直列化し、最後に要求された内容が必ず残ります。
/// - 毎回一意な一時ファイルへ書いてから置き換えるため、途中状態は見えません。
/// - 読めないファイルは `*.corrupt-<時刻>` へ複製してから [CorruptFileException]
///   を投げます。複製できなかった場合は以後の書き込みを拒否し、既定値で上書きして
///   元データを失うことがありません。
class JsonFileStore {
  JsonFileStore(this.file, {required this.maximumBytes, Random? random})
    : _random = random ?? Random.secure();

  final File file;
  final int maximumBytes;
  final Random _random;
  Future<void> _tail = Future<void>.value();
  bool _writeBlocked = false;

  /// ファイルが無ければ `null` を返します。
  Future<Object?> read() async {
    await _tail;
    if (!await file.exists()) return null;
    try {
      final length = await file.length();
      if (length > maximumBytes) {
        throw FormatException('上限 $maximumBytes バイトを超えています ($length)');
      }
      return jsonDecode(utf8.decode(await file.readAsBytes()));
    } on FormatException catch (error) {
      await _quarantine();
      throw CorruptFileException(file.path, error.message);
    }
  }

  /// `value` を書き込みます。並行して呼ばれても要求順に1件ずつ反映されます。
  Future<void> write(Object value) {
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(value),
    );
    final next = _tail.then((_) => _replace(bytes));
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _replace(List<int> bytes) async {
    if (_writeBlocked) {
      throw FileSystemException('破損ファイルを退避できないため保存を中止しました', file.path);
    }
    await file.parent.create(recursive: true);
    final suffix = _random.nextInt(1 << 32).toRadixString(16);
    final temporary = File('${file.path}.$suffix.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      // WindowsのFile.renameはMoveFileExW(MOVEFILE_REPLACE_EXISTING)で置き換えます。
      await temporary.rename(file.path);
    } catch (_) {
      await temporary.delete().catchError((Object _) => temporary);
      rethrow;
    }
  }

  Future<void> _quarantine() async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    try {
      await file.copy('${file.path}.corrupt-$stamp');
    } on FileSystemException {
      _writeBlocked = true;
    }
  }
}

/// 保存ファイルが壊れていたため退避したことを表します。
class CorruptFileException implements Exception {
  const CorruptFileException(this.path, this.reason);

  final String path;
  final String reason;

  @override
  String toString() => '$path を読み込めないため退避しました: $reason';
}
