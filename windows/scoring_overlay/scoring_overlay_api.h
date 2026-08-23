// Project: DAM for Windows Tools
// File: windows/scoring_overlay/scoring_overlay_api.h
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

#ifndef DAM_FOR_WINDOWS_TOOLS_SCORING_OVERLAY_API_H_
#define DAM_FOR_WINDOWS_TOOLS_SCORING_OVERLAY_API_H_

#include <windows.h>

#if defined(DAM_SCORING_OVERLAY_EXPORTS)
#define DAM_SCORING_API extern "C" __declspec(dllexport)
#else
#define DAM_SCORING_API extern "C" __declspec(dllimport)
#endif

/// 描画スレッドを開始し、歌唱技法アイコンを指定ディレクトリから読み込みます。
DAM_SCORING_API BOOL WINAPI DamScoringOverlayStart(
    const wchar_t* asset_directory);

/// 1曲分のカウンターを初期化し、DAMの採点画面内へ表示します。
DAM_SCORING_API void WINAPI DamScoringOverlayBegin();

/// DAM採点エンジンの技法IDと今回増えた回数を表示へ反映します。
DAM_SCORING_API void WINAPI DamScoringOverlayUpdate(int technique_id,
                                                     int value);

/// 現在曲の回数を保ったまま、追加グリッドの表示状態だけを切り替えます。
DAM_SCORING_API void WINAPI DamScoringOverlaySetVisible(BOOL visible);

/// 0回の技法を含む全種類表示と、検出済みだけの表示を切り替えます。
DAM_SCORING_API void WINAPI DamScoringOverlaySetShowZero(BOOL show_zero);

/// 現在曲の表示を閉じ、次の採点開始まで待機します。
DAM_SCORING_API void WINAPI DamScoringOverlayEnd();

/// Frida Agentが生存していることを描画スレッドへ通知します。
DAM_SCORING_API void WINAPI DamScoringOverlayHeartbeat();

/// ウィンドウとGDI+資源を解放し、描画スレッドを終了します。
DAM_SCORING_API void WINAPI DamScoringOverlayStop();

#endif  // DAM_FOR_WINDOWS_TOOLS_SCORING_OVERLAY_API_H_
