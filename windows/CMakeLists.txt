# Project: DAM for Windows Tools
# File: windows/CMakeLists.txt
# Copyright (c) 2026 nnnnnnn0090. All rights reserved.
# Author: nnnnnnn0090
# SPDX-License-Identifier: GPL-3.0-or-later
# Created: 2026-08-22

# Windows版全体のCMake構成を定義します。
cmake_minimum_required(VERSION 3.14)
project(dam_for_windows_tools LANGUAGES CXX)

# 生成するEXEのファイル名です。変更時はRunner側ではなくここだけを更新します。
set(BINARY_NAME "DAMforWindowsTools")

# 新しいCMakeで互換警告が出ないよう、使用するポリシー範囲を明示します。
cmake_policy(VERSION 3.14...3.25)

# 単一構成・複数構成ジェネレーターのビルド種別を統一します。
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# ProfileはReleaseと同じコンパイラー・リンカー設定を使用します。
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# 全ターゲットでWindows Unicode APIを使用します。
add_definitions(-DUNICODE -D_UNICODE)

# Runnerとプラグインへ適用する共通コンパイル設定です。
#
# プラグインも既定で使うため、アプリ固有オプションは各ターゲットへ追加します。
# C++17、UTF-8ソース、警告エラー化、例外処理方式だけをここで統一します。
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  # 日本語コメントをOSの既定コードページに依存せず解釈できるようにします。
  target_compile_options(${TARGET} PRIVATE /utf-8 /W4 /WX /wd4100)
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutterが管理するライブラリとツールのビルドルールを読み込みます。
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# アプリRunner本体のビルド定義を読み込みます。
add_subdirectory("runner")


# Flutterが生成したプラグインのビルド・組み込み規則を読み込みます。
include(flutter/generated_plugins.cmake)


# === 配置処理 ===
# Visual Studioから直接実行できるよう、必要ファイルをEXEと同じ配置先へまとめます。
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# 実行に配置処理が必須なので、Visual Studioの既定ビルドへinstallを含めます。
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# 各パッケージのbuild.dartが生成したWindowsネイティブ資産を配置します。
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# 前回の古いアセットを混在させないよう、毎回削除してから全体を配置します。
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# AOTライブラリはProfileとReleaseだけへ配置します。
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
