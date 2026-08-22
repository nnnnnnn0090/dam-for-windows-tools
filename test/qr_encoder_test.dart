// Project: DAM for Windows Tools
// File: qr_encoder_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:dam_for_windows_tools/presentation/widgets/qr_encoder.dart';
import 'package:flutter_test/flutter_test.dart';

/// QR行列の再現性、正方形構造、ファインダーパターンを検証します。
void main() {
  test('creates a square deterministic QR matrix with finder patterns', () {
    final first = generateQrMatrix('http://192.168.1.10:8766/token/');
    final second = generateQrMatrix('http://192.168.1.10:8766/token/');
    expect(first, second);
    expect(first.length, greaterThanOrEqualTo(21));
    expect(first.every((row) => row.length == first.length), isTrue);
    expect(first[0].take(7), everyElement(isTrue));
    expect(first[6].take(7), everyElement(isTrue));
  });
}
