# Project: DAM for Windows Tools
# File: windows/scoring_overlay/CMakeLists.txt
# Copyright (c) 2026 nnnnnnn0090. All rights reserved.
# Author: nnnnnnn0090
# SPDX-License-Identifier: GPL-3.0-or-later
# Created: 2026-08-23

# DAMプロセス内で動く採点表現描画DLLのビルド条件を定義します。
cmake_minimum_required(VERSION 3.14)
project(dam_scoring_overlay LANGUAGES CXX)

add_library(dam_scoring_overlay SHARED
  "dll_main.cpp"
  "scoring_overlay.cpp"
  "scoring_overlay.h"
  "scoring_overlay_api.h"
)

apply_standard_settings(dam_scoring_overlay)
target_compile_definitions(dam_scoring_overlay PRIVATE "NOMINMAX")
target_link_libraries(dam_scoring_overlay PRIVATE "gdiplus.lib")

# DAMが更新前のDLLを保持中でも新ビルドを配置できるよう、製品版をファイル名へ含めます。
# 公開関数名はC ABIのまま維持し、Frida側がコンパイラー依存名を参照しません。
set_target_properties(dam_scoring_overlay PROPERTIES
  OUTPUT_NAME "dam_scoring_overlay_${FLUTTER_VERSION_MAJOR}_${FLUTTER_VERSION_MINOR}_${FLUTTER_VERSION_PATCH}"
)
