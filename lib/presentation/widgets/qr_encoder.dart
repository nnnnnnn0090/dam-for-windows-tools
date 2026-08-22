// Project: DAM for Windows Tools
// File: qr_encoder.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23
//
// QR行列の構築手順はQRCode for JavaScriptのアルゴリズムを参考にしています。
// 次の行は原著作物のライセンス表示を正確に保つため、原文のまま記載します。
// Copyright (c) 2009 Kazuhiko Arase. Licensed under the MIT License.

import 'dart:convert';
import 'dart:math' as math;

/// UTF-8文字列を、誤り訂正レベルLのQRコード行列へ変換します。
List<List<bool>> generateQrMatrix(String value) => _QrEncoder(value).encode();

/// QRバージョン選択、機能パターン配置、データ配置を順に実行する符号器です。
class _QrEncoder {
  /// 入力文字列をUTF-8バイトへ固定して符号器を生成します。
  _QrEncoder(String value) : bytes = utf8.encode(value);

  final List<int> bytes;
  late int version;
  late int moduleCount;
  late List<List<bool?>> modules;

  static const List<List<int>> _alignmentPositions = <List<int>>[
    <int>[],
    <int>[6, 18],
    <int>[6, 22],
    <int>[6, 26],
    <int>[6, 30],
    <int>[6, 34],
  ];

  static const List<List<_BlockSpec>> _blockSpecs = <List<_BlockSpec>>[
    <_BlockSpec>[_BlockSpec(1, 26, 19)],
    <_BlockSpec>[_BlockSpec(1, 44, 34)],
    <_BlockSpec>[_BlockSpec(1, 70, 55)],
    <_BlockSpec>[_BlockSpec(1, 100, 80)],
    <_BlockSpec>[_BlockSpec(1, 134, 108)],
    <_BlockSpec>[_BlockSpec(2, 86, 68)],
  ];

  /// 入力長に合う最小バージョンを選び、完成した黒白モジュール行列を返します。
  List<List<bool>> encode() {
    version = _selectVersion();
    moduleCount = version * 4 + 17;
    modules = List<List<bool?>>.generate(
      moduleCount,
      (_) => List<bool?>.filled(moduleCount, null),
    );
    _setupFinder(0, 0);
    _setupFinder(moduleCount - 7, 0);
    _setupFinder(0, moduleCount - 7);
    _setupAlignment();
    _setupTiming();
    const mask = 0;
    _setupFormat(mask);
    _mapData(_createCodewords(), mask);
    return modules
        .map(
          (row) => row.map((module) => module ?? false).toList(growable: false),
        )
        .toList(growable: false);
  }

  /// データ容量を超えない最小のQRバージョン1～6を選択します。
  int _selectVersion() {
    for (var candidate = 1; candidate <= _blockSpecs.length; candidate++) {
      final dataBytes = _blockSpecs[candidate - 1].fold<int>(
        0,
        (sum, spec) => sum + spec.count * spec.dataCount,
      );
      final countBits = candidate < 10 ? 8 : 16;
      if (4 + countBits + bytes.length * 8 <= dataBytes * 8) {
        return candidate;
      }
    }
    throw ArgumentError.value(bytes.length, 'value', 'QRデータが長すぎます');
  }

  /// モード・長さ・本文・パディング・誤り訂正をQR配置順のコード語へ変換します。
  List<int> _createCodewords() {
    final specs = _expandedSpecs();
    final totalDataBytes = specs.fold<int>(
      0,
      (sum, spec) => sum + spec.dataCount,
    );
    final bits = _BitBuffer()
      ..put(0x4, 4)
      ..put(bytes.length, version < 10 ? 8 : 16);
    for (final byte in bytes) {
      bits.put(byte, 8);
    }
    final capacity = totalDataBytes * 8;
    bits.put(0, math.min(4, capacity - bits.length));
    while (bits.length % 8 != 0) {
      bits.putBit(false);
    }
    var pad = 0xec;
    while (bits.bytes.length < totalDataBytes) {
      bits.put(pad, 8);
      pad = pad == 0xec ? 0x11 : 0xec;
    }

    final dataBlocks = <List<int>>[];
    final errorBlocks = <List<int>>[];
    var offset = 0;
    for (final spec in specs) {
      final data = bits.bytes.sublist(offset, offset + spec.dataCount);
      offset += spec.dataCount;
      dataBlocks.add(data);
      errorBlocks.add(
        _ReedSolomon.encode(data, spec.totalCount - spec.dataCount),
      );
    }

    final result = <int>[];
    final maximumData = dataBlocks
        .map((block) => block.length)
        .reduce(math.max);
    final maximumError = errorBlocks
        .map((block) => block.length)
        .reduce(math.max);
    for (var index = 0; index < maximumData; index++) {
      for (final block in dataBlocks) {
        if (index < block.length) result.add(block[index]);
      }
    }
    for (var index = 0; index < maximumError; index++) {
      for (final block in errorBlocks) {
        if (index < block.length) result.add(block[index]);
      }
    }
    return result;
  }

  /// 選択バージョンのブロック定義を、実際に処理する1ブロック単位へ展開します。
  List<_BlockSpec> _expandedSpecs() {
    final result = <_BlockSpec>[];
    for (final spec in _blockSpecs[version - 1]) {
      for (var index = 0; index < spec.count; index++) {
        result.add(_BlockSpec(1, spec.totalCount, spec.dataCount));
      }
    }
    return result;
  }

  /// 指定位置へ7×7のファインダーパターンと1セル分の分離領域を配置します。
  void _setupFinder(int row, int column) {
    for (var rowOffset = -1; rowOffset <= 7; rowOffset++) {
      final targetRow = row + rowOffset;
      if (targetRow < 0 || targetRow >= moduleCount) continue;
      for (var columnOffset = -1; columnOffset <= 7; columnOffset++) {
        final targetColumn = column + columnOffset;
        if (targetColumn < 0 || targetColumn >= moduleCount) continue;
        modules[targetRow][targetColumn] =
            (rowOffset >= 0 &&
                rowOffset <= 6 &&
                (columnOffset == 0 || columnOffset == 6)) ||
            (columnOffset >= 0 &&
                columnOffset <= 6 &&
                (rowOffset == 0 || rowOffset == 6)) ||
            (rowOffset >= 2 &&
                rowOffset <= 4 &&
                columnOffset >= 2 &&
                columnOffset <= 4);
      }
    }
  }

  /// 選択バージョンに必要なアライメントパターンを未使用セルへ配置します。
  void _setupAlignment() {
    final positions = _alignmentPositions[version - 1];
    for (final row in positions) {
      for (final column in positions) {
        if (modules[row][column] != null) continue;
        for (var rowOffset = -2; rowOffset <= 2; rowOffset++) {
          for (var columnOffset = -2; columnOffset <= 2; columnOffset++) {
            modules[row + rowOffset][column + columnOffset] =
                rowOffset.abs() == 2 ||
                columnOffset.abs() == 2 ||
                (rowOffset == 0 && columnOffset == 0);
          }
        }
      }
    }
  }

  /// ファインダーパターン間へ交互のタイミングパターンを配置します。
  void _setupTiming() {
    for (var index = 8; index < moduleCount - 8; index++) {
      modules[index][6] ??= index.isEven;
      modules[6][index] ??= index.isEven;
    }
  }

  /// 誤り訂正レベルLとマスク番号から、形式情報と固定暗モジュールを配置します。
  void _setupFormat(int mask) {
    final bits = _formatBits((1 << 3) | mask);
    for (var index = 0; index < 15; index++) {
      final dark = ((bits >> index) & 1) == 1;
      final verticalRow = index < 6
          ? index
          : index < 8
          ? index + 1
          : moduleCount - 15 + index;
      modules[verticalRow][8] = dark;

      final horizontalColumn = index < 8
          ? moduleCount - index - 1
          : index < 9
          ? 15 - index
          : 14 - index;
      modules[8][horizontalColumn] = dark;
    }
    modules[moduleCount - 8][8] = true;
  }

  /// BCH符号と固定マスクを用いて15ビットの形式情報を生成します。
  int _formatBits(int data) {
    const generator = 0x537;
    var remainder = data << 10;
    while (_bitLength(remainder) >= _bitLength(generator)) {
      remainder ^= generator << (_bitLength(remainder) - _bitLength(generator));
    }
    return ((data << 10) | remainder) ^ 0x5412;
  }

  /// 正の整数を表現するために必要なビット数を返します。
  int _bitLength(int value) {
    var length = 0;
    while (value != 0) {
      length++;
      value >>= 1;
    }
    return length;
  }

  /// 予約済み機能セルを避け、右下から2列ずつデータビットを配置します。
  void _mapData(List<int> data, int mask) {
    var direction = -1;
    var row = moduleCount - 1;
    var bitIndex = 7;
    var byteIndex = 0;
    for (var column = moduleCount - 1; column > 0; column -= 2) {
      if (column == 6) column--;
      while (true) {
        for (var offset = 0; offset < 2; offset++) {
          final targetColumn = column - offset;
          if (modules[row][targetColumn] != null) continue;
          var dark =
              byteIndex < data.length &&
              ((data[byteIndex] >> bitIndex) & 1) == 1;
          if ((row + targetColumn).isEven) dark = !dark;
          modules[row][targetColumn] = dark;
          bitIndex--;
          if (bitIndex < 0) {
            byteIndex++;
            bitIndex = 7;
          }
        }
        row += direction;
        if (row < 0 || row >= moduleCount) {
          row -= direction;
          direction = -direction;
          break;
        }
      }
    }
  }
}

/// QR仕様のブロック数、総コード語数、データコード語数を表します。
class _BlockSpec {
  /// 1種類の誤り訂正ブロック構成を生成します。
  const _BlockSpec(this.count, this.totalCount, this.dataCount);

  final int count;
  final int totalCount;
  final int dataCount;
}

/// 可変長ビット列を保持し、QRコード語へ変換する作業用バッファです。
class _BitBuffer {
  final List<bool> _bits = <bool>[];

  /// 現在格納しているビット数を返します。
  int get length => _bits.length;

  /// 先頭ビットから8ビットずつまとめたバイト列を返します。
  List<int> get bytes {
    final result = List<int>.filled((_bits.length + 7) ~/ 8, 0);
    for (var index = 0; index < _bits.length; index++) {
      if (_bits[index]) result[index ~/ 8] |= 0x80 >> (index % 8);
    }
    return result;
  }

  /// 整数の上位ビットから指定長だけバッファへ追加します。
  void put(int value, int length) {
    for (var index = length - 1; index >= 0; index--) {
      putBit(((value >> index) & 1) == 1);
    }
  }

  /// 1ビットを現在の末尾へ追加します。
  void putBit(bool value) => _bits.add(value);
}

/// GF(256)上のリード・ソロモン誤り訂正コードを生成します。
class _ReedSolomon {
  static final List<int> _exponents = _createExponents();
  static final List<int> _logarithms = _createLogarithms();

  /// データコード語から指定長の誤り訂正コード語を生成します。
  static List<int> encode(List<int> data, int errorLength) {
    var generator = <int>[1];
    for (var index = 0; index < errorLength; index++) {
      final next = List<int>.filled(generator.length + 1, 0);
      for (var coefficient = 0; coefficient < generator.length; coefficient++) {
        next[coefficient] ^= generator[coefficient];
        next[coefficient + 1] ^= _multiply(
          generator[coefficient],
          _exponents[index],
        );
      }
      generator = next;
    }
    final message = <int>[...data, ...List<int>.filled(errorLength, 0)];
    for (var index = 0; index < data.length; index++) {
      final factor = message[index];
      if (factor == 0) continue;
      for (var coefficient = 0; coefficient < generator.length; coefficient++) {
        message[index + coefficient] ^= _multiply(
          generator[coefficient],
          factor,
        );
      }
    }
    return message.sublist(data.length);
  }

  /// 指数表と対数表を使ってGF(256)上の乗算を行います。
  static int _multiply(int left, int right) {
    if (left == 0 || right == 0) return 0;
    return _exponents[_logarithms[left] + _logarithms[right]];
  }

  /// 原始多項式0x11dから、周期を複製した指数表を生成します。
  static List<int> _createExponents() {
    final result = List<int>.filled(512, 0);
    var value = 1;
    for (var index = 0; index < 255; index++) {
      result[index] = value;
      value <<= 1;
      if ((value & 0x100) != 0) value ^= 0x11d;
    }
    for (var index = 255; index < result.length; index++) {
      result[index] = result[index - 255];
    }
    return result;
  }

  /// 指数表を逆引きする対数表を生成します。
  static List<int> _createLogarithms() {
    final result = List<int>.filled(256, 0);
    for (var index = 0; index < 255; index++) {
      result[_exponents[index]] = index;
    }
    return result;
  }
}
