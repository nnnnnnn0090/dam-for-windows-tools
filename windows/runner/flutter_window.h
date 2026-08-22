// Project: DAM for Windows Tools
// File: flutter_window.h
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

/// Flutterビューをホストし、安全な終了確認チャネルを提供するWin32ウィンドウです。
class FlutterWindow : public Win32Window {
 public:
  /// 指定Dartプロジェクトを実行するFlutterウィンドウを生成します。
  explicit FlutterWindow(const flutter::DartProject& project);
  /// Flutterコントローラーとネイティブチャネルを破棄します。
  virtual ~FlutterWindow();

 protected:
  /// Flutterエンジン、プラグイン、終了チャネルを初期化します。
  bool OnCreate() override;
  /// ネイティブチャネルとFlutterエンジンを解放します。
  void OnDestroy() override;
  /// Flutterへ先にメッセージを渡し、閉じる要求だけは清掃完了まで保留します。
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // このウィンドウで実行するDartプロジェクトです。
  flutter::DartProject project_;

  // ウィンドウが所有するFlutterエンジンとビューです。
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Dart側がDAMパッチ復元、FFmpeg停止、セッション削除を終えるまで
  // ネイティブウィンドウの破棄を保留するチャネルです。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      lifecycle_channel_;
  bool close_requested_ = false;
  bool close_ready_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_ の終端
