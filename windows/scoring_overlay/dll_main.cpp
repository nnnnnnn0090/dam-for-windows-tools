// Project: DAM for Windows Tools
// File: windows/scoring_overlay/dll_main.cpp
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

#define DAM_SCORING_OVERLAY_EXPORTS
#include "scoring_overlay_api.h"

#include <new>
#include <string>

#include "scoring_overlay.h"

namespace {

HINSTANCE g_module = nullptr;
ScoringOverlay* g_overlay = nullptr;
SRWLOCK g_overlay_lock = SRWLOCK_INIT;

/// 既存インスタンスを返し、未生成なら検証済みパスから1つだけ生成します。
bool StartOverlay(const wchar_t* asset_directory) {
  if (asset_directory == nullptr || asset_directory[0] == L'\0') {
    return false;
  }
  AcquireSRWLockExclusive(&g_overlay_lock);
  if (g_overlay != nullptr) {
    g_overlay->Heartbeat();
    ReleaseSRWLockExclusive(&g_overlay_lock);
    return true;
  }
  ScoringOverlay* candidate =
      new (std::nothrow) ScoringOverlay(g_module, asset_directory);
  if (candidate == nullptr || !candidate->Start()) {
    delete candidate;
    ReleaseSRWLockExclusive(&g_overlay_lock);
    return false;
  }
  g_overlay = candidate;
  ReleaseSRWLockExclusive(&g_overlay_lock);
  return true;
}

/// 現在インスタンスへ、短時間で完了する更新処理を排他的に渡します。
template <typename Callback>
void WithOverlay(Callback callback) {
  AcquireSRWLockExclusive(&g_overlay_lock);
  if (g_overlay != nullptr) {
    callback(*g_overlay);
  }
  ReleaseSRWLockExclusive(&g_overlay_lock);
}

}  // namespace

/// DLLインスタンスを保存し、不要なスレッド通知を止めます。
BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, void*) {
  if (reason == DLL_PROCESS_ATTACH) {
    g_module = module;
    DisableThreadLibraryCalls(module);
  }
  return TRUE;
}

/// 描画スレッドを開始し、起動結果をFrida Agentへ返します。
BOOL WINAPI DamScoringOverlayStart(const wchar_t* asset_directory) {
  return StartOverlay(asset_directory) ? TRUE : FALSE;
}

/// 新しい採点セッションを表示へ反映します。
void WINAPI DamScoringOverlayBegin() {
  WithOverlay([](ScoringOverlay& overlay) { overlay.Begin(); });
}

/// 今回検知した歌唱技法を現在セッションへ加算します。
void WINAPI DamScoringOverlayUpdate(int technique_id, int value) {
  WithOverlay([technique_id, value](ScoringOverlay& overlay) {
    overlay.Update(technique_id, value);
  });
}

/// 現在曲の回数へ触れず、停止・一時停止・再開に表示だけを追従させます。
void WINAPI DamScoringOverlaySetVisible(BOOL visible) {
  WithOverlay([visible](ScoringOverlay& overlay) {
    overlay.SetVisible(visible != FALSE);
  });
}

/// 利用者設定に合わせて、未検出タイルの描画有無を即時反映します。
void WINAPI DamScoringOverlaySetShowZero(BOOL show_zero) {
  WithOverlay([show_zero](ScoringOverlay& overlay) {
    overlay.SetShowZero(show_zero != FALSE);
  });
}

/// 採点終了に合わせてグリッドを閉じます。
void WINAPI DamScoringOverlayEnd() {
  WithOverlay([](ScoringOverlay& overlay) { overlay.End(); });
}

/// Agentの定期通知で孤立した表示が残らないようにします。
void WINAPI DamScoringOverlayHeartbeat() {
  WithOverlay([](ScoringOverlay& overlay) { overlay.Heartbeat(); });
}

/// グローバル参照を先に外し、終了待機中の追加更新を遮断してから破棄します。
void WINAPI DamScoringOverlayStop() {
  AcquireSRWLockExclusive(&g_overlay_lock);
  ScoringOverlay* overlay = g_overlay;
  g_overlay = nullptr;
  ReleaseSRWLockExclusive(&g_overlay_lock);
  if (overlay != nullptr) {
    overlay->Stop();
    delete overlay;
  }
}
