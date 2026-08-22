// Project: DAM for Windows Tools
// File: qr_code_view.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'qr_encoder.dart';

export 'qr_encoder.dart' show generateQrMatrix;

class QrCodeView extends StatelessWidget {
  const QrCodeView({super.key, required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    try {
      final modules = generateQrMatrix(data);
      return Semantics(
        image: true,
        label: 'リモコン接続用QRコード',
        child: CustomPaint(
          size: Size.square(size),
          painter: _QrPainter(modules),
        ),
      );
    } on Object {
      return SizedBox.square(
        dimension: size,
        child: const Center(
          child: Text(
            'QRコードを\n生成できません',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black87),
          ),
        ),
      );
    }
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.modules);

  final List<List<bool>> modules;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final count = modules.length;
    const quietZone = 4;
    final scale = math.min(size.width, size.height) / (count + quietZone * 2);
    final left = (size.width - scale * (count + quietZone * 2)) / 2;
    final top = (size.height - scale * (count + quietZone * 2)) / 2;
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var row = 0; row < count; row++) {
      for (var column = 0; column < count; column++) {
        if (!modules[row][column]) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            left + (column + quietZone) * scale,
            top + (row + quietZone) * scale,
            scale,
            scale,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) =>
      oldDelegate.modules != modules;
}
