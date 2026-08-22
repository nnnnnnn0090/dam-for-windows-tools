# Project: DAM for Windows Tools
# File: windows/runner/CMakeLists.txt
# Copyright (c) 2026 nnnnnnn0090. All rights reserved.
# Author: nnnnnnn0090
# SPDX-License-Identifier: GPL-3.0-or-later
# Created: 2026-08-22

cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# アプリ本体のターゲットを定義します。名前はトップ階層のBINARY_NAMEだけで変更し、
# `flutter run`と生成規則の整合性を維持します。
#
# 新しいネイティブソースはこの一覧へ追加します。
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# トップ階層で定義したWindows共通ビルド設定を適用します。
apply_standard_settings(${BINARY_NAME})

# Flutterのビルド版をEXEリソース用プリプロセッサー定義へ渡します。
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# C++標準ライブラリ関数と衝突するWindowsのmin/maxマクロを無効化します。
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Flutterラッパーとダーク枠設定に必要なDWMライブラリをリンクします。
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Runnerより先にFlutterアセットとAOT成果物を生成します。
add_dependencies(${BINARY_NAME} flutter_assemble)
