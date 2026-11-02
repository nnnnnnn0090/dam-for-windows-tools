import 'dart:math';

final Random _secure = Random.secure();

/// 暗号論的乱数から `bytes` バイト分の小文字16進文字列を生成します。
String randomHex(int bytes) {
  final buffer = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buffer.write(_secure.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
