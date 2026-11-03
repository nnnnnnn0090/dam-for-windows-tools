#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <optional>
#include <string>
#include <vector>

#include "app_config.h"
#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr UINT_PTR kCloseTimeoutTimer = 1;
constexpr UINT kCloseTimeoutMs = 20000;
constexpr DWORD kEndSessionTimeoutMs = 10000;

std::wstring Utf16FromUtf8(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  int length = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                                     static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring result(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                        static_cast<int>(text.size()), result.data(), length);
  return result;
}

const EncodableValue* Argument(const EncodableValue* arguments, const char* key) {
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) {
    return nullptr;
  }
  auto found = map->find(EncodableValue(key));
  return found == map->end() ? nullptr : &found->second;
}

std::optional<std::string> StringArgument(const EncodableValue* arguments, const char* key) {
  const auto* value = Argument(arguments, key);
  const auto* text = value == nullptr ? nullptr : std::get_if<std::string>(value);
  return text == nullptr ? std::nullopt : std::optional<std::string>(*text);
}

std::vector<std::wstring> StringListArgument(const EncodableValue* arguments, const char* key) {
  std::vector<std::wstring> items;
  const auto* value = Argument(arguments, key);
  const auto* list = value == nullptr ? nullptr : std::get_if<EncodableList>(value);
  if (list != nullptr) {
    for (const auto& item : *list) {
      if (const auto* text = std::get_if<std::string>(&item)) {
        items.push_back(Utf16FromUtf8(*text));
      }
    }
  }
  return items;
}

// CommandLineToArgvW と同じ規則で1つの引数を引用符付けします。
void AppendQuotedArgument(std::wstring& command_line, const std::wstring& argument) {
  if (!command_line.empty()) {
    command_line.push_back(L' ');
  }
  if (!argument.empty() && argument.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
    command_line.append(argument);
    return;
  }
  command_line.push_back(L'"');
  for (auto it = argument.begin();; ++it) {
    size_t backslashes = 0;
    while (it != argument.end() && *it == L'\\') {
      ++it;
      ++backslashes;
    }
    if (it == argument.end()) {
      command_line.append(backslashes * 2, L'\\');
      break;
    }
    if (*it == L'"') {
      command_line.append(backslashes * 2 + 1, L'\\');
    } else {
      command_line.append(backslashes, L'\\');
    }
    command_line.push_back(*it);
  }
  command_line.push_back(L'"');
}

// ジョブオブジェクトの外で起動します。更新プログラムがアプリ終了後も動けるようにします。
bool LaunchDetached(const std::wstring& executable, const std::vector<std::wstring>& arguments) {
  std::wstring command_line;
  AppendQuotedArgument(command_line, executable);
  for (const auto& argument : arguments) {
    AppendQuotedArgument(command_line, argument);
  }
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!::CreateProcessW(executable.c_str(), command_line.data(), nullptr, nullptr, FALSE,
                        CREATE_BREAKAWAY_FROM_JOB | DETACHED_PROCESS | CREATE_UNICODE_ENVIRONMENT,
                        nullptr, nullptr, &startup, &process)) {
    return false;
  }
  ::CloseHandle(process.hThread);
  ::CloseHandle(process.hProcess);
  return true;
}

// 動画ファイルを1つ選びます。キャンセル時は空文字列です。
std::optional<std::wstring> PickFile(HWND owner, const std::vector<std::wstring>& extensions) {
  ComPtr<IFileOpenDialog> dialog;
  if (FAILED(::CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&dialog)))) {
    return std::nullopt;
  }
  std::wstring pattern;
  for (const auto& extension : extensions) {
    if (!pattern.empty()) {
      pattern.push_back(L';');
    }
    pattern.append(L"*.").append(extension);
  }
  const COMDLG_FILTERSPEC filters[] = {{L"動画ファイル", pattern.c_str()}};
  dialog->SetFileTypes(1, filters);
  dialog->SetTitle(L"差し替え動画を選択");
  DWORD options = 0;
  dialog->GetOptions(&options);
  dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST);
  if (dialog->Show(owner) != S_OK) {
    return std::wstring();
  }
  ComPtr<IShellItem> item;
  PWSTR path = nullptr;
  if (FAILED(dialog->GetResult(&item)) || FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
    return std::nullopt;
  }
  std::wstring result(path);
  ::CoTaskMemFree(path);
  return result;
}

// MP4の保存先を選びます。キャンセル時は空文字列です。
std::optional<std::wstring> PickSaveFile(HWND owner, const std::wstring& file_name) {
  ComPtr<IFileSaveDialog> dialog;
  if (FAILED(::CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&dialog)))) {
    return std::nullopt;
  }
  const COMDLG_FILTERSPEC filters[] = {{L"MP4 動画", L"*.mp4"}};
  dialog->SetFileTypes(1, filters);
  dialog->SetDefaultExtension(L"mp4");
  dialog->SetTitle(L"公式動画を書き出し");
  if (!file_name.empty()) {
    dialog->SetFileName(file_name.c_str());
  }
  DWORD options = 0;
  dialog->GetOptions(&options);
  dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT | FOS_PATHMUSTEXIST);
  if (dialog->Show(owner) != S_OK) {
    return std::wstring();
  }
  ComPtr<IShellItem> item;
  PWSTR path = nullptr;
  if (FAILED(dialog->GetResult(&item)) || FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
    return std::nullopt;
  }
  std::wstring result(path);
  ::CoTaskMemFree(path);
  return result;
}

// ファイルを選択した状態でエクスプローラーを開きます。
bool RevealFile(const std::wstring& path) {
  PIDLIST_ABSOLUTE item = ::ILCreateFromPathW(path.c_str());
  if (item == nullptr) {
    return false;
  }
  HRESULT hr = ::SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
  ::ILFree(item);
  return SUCCEEDED(hr);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project) : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      flutter_controller_->engine()->messenger(), APP_LIFECYCLE_CHANNEL,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::OnDestroy() {
  channel_ = nullptr;
  flutter_controller_ = nullptr;
  Win32Window::OnDestroy();
}

void FlutterWindow::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto& method = call.method_name();
  const auto* arguments = call.arguments();
  if (method == "closeReady") {
    close_ready_ = true;
    ::KillTimer(GetHandle(), kCloseTimeoutTimer);
    ::PostMessage(GetHandle(), WM_CLOSE, 0, 0);
    result->Success();
  } else if (method == "pickVideoFile") {
    auto path = PickFile(GetHandle(), StringListArgument(arguments, "extensions"));
    if (!path) {
      result->Error("dialog", "ファイル選択画面を開けません");
    } else if (path->empty()) {
      result->Success();
    } else {
      result->Success(EncodableValue(Utf8FromUtf16(path->c_str())));
    }
  } else if (method == "pickSaveFile") {
    auto path = PickSaveFile(GetHandle(),
                             Utf16FromUtf8(StringArgument(arguments, "fileName").value_or("")));
    if (!path) {
      result->Error("dialog", "保存画面を開けません");
    } else if (path->empty()) {
      result->Success();
    } else {
      result->Success(EncodableValue(Utf8FromUtf16(path->c_str())));
    }
  } else if (method == "revealFile") {
    auto path = StringArgument(arguments, "path");
    if (!path || !RevealFile(Utf16FromUtf8(*path))) {
      result->Error("shell", "エクスプローラーを開けません");
    } else {
      result->Success();
    }
  } else if (method == "openUrl") {
    auto url = StringArgument(arguments, "url");
    if (!url || url->rfind("http://", 0) != 0) {
      result->Error("argument", "http:// のURLだけを開けます");
      return;
    }
    auto opened = ::ShellExecuteW(GetHandle(), L"open", Utf16FromUtf8(*url).c_str(), nullptr,
                                  nullptr, SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(opened) <= 32) {
      result->Error("shell", "ブラウザを開けません");
    } else {
      result->Success();
    }
  } else if (method == "launchDetached") {
    auto executable = StringArgument(arguments, "executable");
    if (!executable || !LaunchDetached(Utf16FromUtf8(*executable),
                                       StringListArgument(arguments, "arguments"))) {
      result->Error("launch", "プロセスを起動できません", EncodableValue(static_cast<int>(::GetLastError())));
    } else {
      result->Success();
    }
  } else {
    result->NotImplemented();
  }
}

void FlutterWindow::RequestClose() {
  if (close_requested_) {
    return;
  }
  close_requested_ = true;
  // Dartが応答しない・例外で止まった場合でも、時間が来たら閉じます。
  ::SetTimer(GetHandle(), kCloseTimeoutTimer, kCloseTimeoutMs, nullptr);
  if (channel_) {
    channel_->InvokeMethod("closeRequested", nullptr);
  } else {
    close_ready_ = true;
    ::PostMessage(GetHandle(), WM_CLOSE, 0, 0);
  }
}

void FlutterWindow::WaitForCloseReady(DWORD timeout_ms) {
  // ログオフ時はこの応答から戻るとプロセスが終了させられるため、ここでDartの
  // 停止処理（チャネル応答を含む）が終わるまでメッセージを処理しながら待ちます。
  ULONGLONG deadline = ::GetTickCount64() + timeout_ms;
  while (!close_ready_) {
    ULONGLONG now = ::GetTickCount64();
    if (now >= deadline) {
      break;
    }
    ::MsgWaitForMultipleObjects(0, nullptr, FALSE, static_cast<DWORD>(deadline - now), QS_ALLINPUT);
    MSG msg;
    while (::PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
  }
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message, WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  switch (message) {
    case WM_CLOSE:
      if (!close_ready_) {
        RequestClose();
        return 0;
      }
      break;
    case WM_TIMER:
      if (wparam == kCloseTimeoutTimer) {
        ::KillTimer(hwnd, kCloseTimeoutTimer);
        close_ready_ = true;
        ::PostMessage(hwnd, WM_CLOSE, 0, 0);
        return 0;
      }
      break;
    case WM_QUERYENDSESSION:
      return TRUE;
    case WM_ENDSESSION:
      if (wparam) {
        RequestClose();
        WaitForCloseReady(kEndSessionTimeoutMs);
      }
      return 0;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    if (result) {
      return *result;
    }
  }

  if (message == WM_FONTCHANGE && flutter_controller_) {
    flutter_controller_->engine()->ReloadSystemFonts();
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
