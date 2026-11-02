#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "app_config.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

// 既に起動しているウィンドウを手前に出します。最大化状態は保ちます。
void ActivateExistingWindow() {
  HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", APP_PRODUCT_NAME_W);
  if (existing == nullptr) {
    return;
  }
  ::ShowWindow(existing, ::IsIconic(existing) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(existing);
}

// 自プロセスをジョブオブジェクトに入れ、アプリが異常終了しても接続ヘルパーや
// FFmpegなどの子プロセスが残らないようにします。更新プログラムだけは
// CREATE_BREAKAWAY_FROM_JOB でジョブ外に起動します（flutter_window.cpp）。
void ConfineChildProcessesToJob() {
  HANDLE job = ::CreateJobObjectW(nullptr, nullptr);
  if (job == nullptr) {
    return;
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
  if (!::SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                 &limits, sizeof(limits)) ||
      !::AssignProcessToJobObject(job, ::GetCurrentProcess())) {
    ::CloseHandle(job);
  }
  // 成功時はハンドルを閉じません。プロセス終了で閉じられ、子プロセスも終了します。
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  // CreateMutexW直後のGetLastErrorで判定するため、Dart側ではなくここで行います。
  HANDLE singleton = ::CreateMutexW(nullptr, FALSE, APP_SINGLETON_MUTEX);
  if (singleton == nullptr || ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateExistingWindow();
    return EXIT_SUCCESS;
  }
  ConfineChildProcessesToJob();

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(GetCommandLineArguments());

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(APP_PRODUCT_NAME_W, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(singleton);
  return EXIT_SUCCESS;
}
