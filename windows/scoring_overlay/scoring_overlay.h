// Project: DAM for Windows Tools
// File: windows/scoring_overlay/scoring_overlay.h
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

#ifndef DAM_FOR_WINDOWS_TOOLS_SCORING_OVERLAY_H_
#define DAM_FOR_WINDOWS_TOOLS_SCORING_OVERLAY_H_

#include <windows.h>

#include <string>

/// DAMのクライアント領域へ、既存MusicStaffと同系統の歌唱技法表示を重ねます。
///
/// 描画は専用スレッドへ閉じ込め、採点フック側ではカウンター更新だけを行います。
/// DAMのレンダリング資源や元の4カウンター構造体は変更しません。
class ScoringOverlay final {
 public:
  /// DLLインスタンスと検証済みアイコンディレクトリを保持します。
  ScoringOverlay(HINSTANCE module, std::wstring asset_directory);

  /// 残っている描画スレッドがあれば停止してから内部資源を破棄します。
  ~ScoringOverlay();

  ScoringOverlay(const ScoringOverlay&) = delete;
  ScoringOverlay& operator=(const ScoringOverlay&) = delete;

  /// DAMの主要ウィンドウを探索し、所有関係を持つ透過描画ウィンドウを開始します。
  bool Start();

  /// 全カウンターを0へ戻し、歌唱中のグリッドを表示します。
  void Begin();

  /// 44個のエンジンIDを表示用35分類へ正規化して加算します。
  void Update(int technique_id, int value);

  /// カウンターを初期化せず、現在曲のグリッドだけを表示または非表示にします。
  void SetVisible(bool visible);

  /// 未検出の0回タイルをグリッドへ含めるか切り替えます。
  void SetShowZero(bool show_zero);

  /// 現在曲のグリッドを非表示にします。
  void End();

  /// Agent切断を自動検知するための最終生存時刻を更新します。
  void Heartbeat();

  /// メッセージループを終了させ、スレッドの完了を待ちます。
  void Stop();

 private:
  class Impl;
  Impl* impl_ = nullptr;
};

#endif  // DAM_FOR_WINDOWS_TOOLS_SCORING_OVERLAY_H_
