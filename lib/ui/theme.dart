import 'package:flutter/material.dart';

/// 画面で使う色です。部品ごとに色を直書きせず、ここから参照します。
abstract final class AppColors {
  static const background = Color(0xff111318);
  static const surface = Color(0xff171a1f);
  static const header = Color(0xff191c21);
  static const tabBar = Color(0xff15181d);
  static const tableHeader = Color(0xff1d2026);
  static const border = Color(0xff333840);
  static const rowBorder = Color(0xff292d34);
  static const inputBorder = Color(0xff454b55);
  static const accent = Color(0xff5b9bd5);
  static const tabIndicator = Color(0xff4e91cb);

  static const text = Color(0xffd4d7dc);
  static const textStrong = Color(0xffe0e3e8);
  static const textMuted = Color(0xff9298a1);
  static const textFaint = Color(0xff888e98);

  static const ok = Color(0xff4fb477);
  static const warning = Color(0xffc59a46);
  static const error = Color(0xffd96767);
  static const info = Color(0xff65a5dc);
  static const caution = Color(0xffffc66d);
}

abstract final class AppTheme {
  /// 長時間の利用でも眩しさを抑えたダークテーマです。
  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accent,
      onPrimary: Colors.white,
      secondary: AppColors.accent,
      surface: AppColors.surface,
      error: AppColors.error,
    ),
    scaffoldBackgroundColor: AppColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.header,
      foregroundColor: Color(0xffe5e7ea),
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: AppColors.border)),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: AppColors.background,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: AppColors.inputBorder),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    ),
    textButtonTheme: const TextButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(3)),
          ),
        ),
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 350),
    ),
  );
}
