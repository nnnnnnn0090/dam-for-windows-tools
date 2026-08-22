// Project: DAM for Windows Tools
// File: flutter_window.cpp
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

#include "flutter_window.h"

#include <optional>

#include "app_config.h"
#include "flutter/generated_plugin_registrant.h"

/// Dartプロジェクトを保持する未初期化ウィンドウを生成します。
FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

/// 基底クラスの破棄手順へ委譲します。
FlutterWindow::~FlutterWindow() {}

/// クライアント領域と同寸法のFlutterビューを作り、終了通知チャネルを接続します。
bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // 起動時の不要な描画面作成・破棄を避けるため、現在のクライアント領域と同寸法にします。
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // エンジンとビューの両方が生成できた場合だけ初期化成功とします。
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  lifecycle_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), APP_LIFECYCLE_CHANNEL,
          &flutter::StandardMethodCodec::GetInstance());
  lifecycle_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "closeReady") {
          close_ready_ = true;
          result->Success();
          if (GetHandle()) {
            PostMessage(GetHandle(), WM_CLOSE, 0, 0);
          }
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // コールバック登録前に初回フレームが完了する場合があるため、再描画を予約して
  // 表示通知を確実に発生させます。未完了ならこの呼び出しは実質何もしません。
  flutter_controller_->ForceRedraw();

  return true;
}

/// 終了チャネルを先に外し、Flutterコントローラーを解放します。
void FlutterWindow::OnDestroy() {
  lifecycle_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

/// Flutter未処理のWin32メッセージを扱い、WM_CLOSEをDart清掃完了まで保留します。
LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 独自処理の前に、Flutter本体とプラグインへウィンドウメッセージを渡します。
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_CLOSE:
      if (!close_ready_) {
        if (!close_requested_ && lifecycle_channel_) {
          close_requested_ = true;
          lifecycle_channel_->InvokeMethod(
              "closeRequested",
              std::make_unique<flutter::EncodableValue>());
        }
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
