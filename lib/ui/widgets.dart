import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'qr_encoder.dart';
import 'theme.dart';

/// 枠線付きの区画です。
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.surface,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(4),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

/// 区画の見出し行です。右側に操作ボタンを置けます。
class PanelHeader extends StatelessWidget {
  const PanelHeader(this.title, {super.key, this.trailing = const <Widget>[]});

  final String title;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 43,
    child: Row(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        const Spacer(),
        ...trailing,
        const SizedBox(width: 6),
      ],
    ),
  );
}

/// 説明文付きのチェックボックスです。
class SettingCheckbox extends StatelessWidget {
  const SettingCheckbox({
    super.key,
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => onChanged(!value),
    child: Row(
      children: <Widget>[
        Checkbox(
          value: value,
          onChanged: (next) => onChanged(next ?? false),
          visualDensity: VisualDensity.compact,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.25,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// 小さな丸い状態表示です。
class StatusDot extends StatelessWidget {
  const StatusDot(this.color, {super.key});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// QRコードです。生成できない長さのデータでは代わりに説明を表示します。
class QrCodeView extends StatelessWidget {
  const QrCodeView({super.key, required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final List<List<bool>> modules;
    try {
      modules = generateQrMatrix(data);
    } on ArgumentError {
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
    return Semantics(
      image: true,
      label: 'リモコン接続用QRコード',
      child: CustomPaint(size: Size.square(size), painter: _QrPainter(modules)),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.modules);

  final List<List<bool>> modules;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    const quietZone = 4;
    final count = modules.length;
    final scale = math.min(size.width, size.height) / (count + quietZone * 2);
    final origin = Offset(
      (size.width - scale * (count + quietZone * 2)) / 2,
      (size.height - scale * (count + quietZone * 2)) / 2,
    );
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var row = 0; row < count; row++) {
      for (var column = 0; column < count; column++) {
        if (!modules[row][column]) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            origin.dx + (column + quietZone) * scale,
            origin.dy + (row + quietZone) * scale,
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
