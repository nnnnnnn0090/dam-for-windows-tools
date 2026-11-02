#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// Flutterを表示するウィンドウです。
//
// 閉じる操作（×ボタン・ログオフ）はDartへ `closeRequested` で知らせ、DAMへの変更の
// 復元などの停止処理が終わって `closeReady` が届いてから実際に閉じます。Dartが
// 応答しない場合も、一定時間後には必ず閉じます。
class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void RequestClose();
  void WaitForCloseReady(DWORD timeout_ms);

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool close_requested_ = false;
  bool close_ready_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
