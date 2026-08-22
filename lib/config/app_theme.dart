// Project: DAM for Windows Tools
// File: app_theme.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';

/// WindowsデスクトップGUIで共通使用する色・余白・部品形状を定義します。
abstract final class AppTheme {
  /// 長時間のカラオケ利用でも眩しさを抑えた、製品共通のダークテーマを返します。
  static ThemeData get dark => ThemeData(
    colorScheme: const ColorScheme.dark(
      primary: Color(0xff5b9bd5),
      onPrimary: Colors.white,
      secondary: Color(0xff5b9bd5),
      surface: Color(0xff171a1f),
      error: Color(0xffd96767),
    ),
    useMaterial3: true,
    scaffoldBackgroundColor: const Color(0xff111318),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xff191c21),
      foregroundColor: Color(0xffe5e7ea),
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: Color(0xff333840))),
    ),
    cardTheme: const CardThemeData(
      color: Color(0xff171a1f),
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(4)),
        side: BorderSide(color: Color(0xff333840)),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xff333840),
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Color(0xff111318),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: Color(0xff454b55)),
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
