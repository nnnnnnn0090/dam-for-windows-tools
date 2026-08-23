// Project: DAM for Windows Tools
// File: windows/scoring_overlay/scoring_overlay.cpp
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

#include "scoring_overlay.h"

#include <gdiplus.h>
#include <process.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cwchar>
#include <new>
#include <string>

namespace {

constexpr UINT kRefreshMessage = WM_APP + 0x4D1;
constexpr UINT_PTR kFollowTimer = 1;
constexpr UINT kFollowIntervalMilliseconds = 100;
constexpr ULONGLONG kHeartbeatTimeoutMilliseconds = 3500;
constexpr ULONGLONG kHighlightMilliseconds = 700;
constexpr int kReferenceWidth = 1920;
constexpr int kReferenceHeight = 1080;
constexpr int kColumnCount = 7;

/// 表示上の技法IDと日本語名を1対1で保持します。
struct TechniqueDefinition {
  int id;
  const wchar_t* name;
};

constexpr std::array<TechniqueDefinition, 35> kTechniques{{
    {0, L"しゃくり"},
    {1, L"大しゃくり"},
    {2, L"早いしゃくり"},
    {3, L"早いしゃくり（強）"},
    {4, L"L字アクセント"},
    {5, L"L字アクセント（強）"},
    {6, L"V字アクセント"},
    {7, L"V字アクセント（カット）"},
    {8, L"V字アクセント（下）"},
    {9, L"逆V字アクセント"},
    {10, L"先頭こぶし"},
    {11, L"こぶし"},
    {12, L"フライダウン"},
    {13, L"ハンマリング・オン"},
    {14, L"プリング・オフ"},
    {15, L"上昇ポルタメント"},
    {16, L"下降ポルタメント"},
    {17, L"上昇スロープ"},
    {18, L"フォール"},
    {19, L"早いフォール"},
    {20, L"ヒーカップ"},
    {21, L"フォール付きヒーカップ"},
    {22, L"スローダウン"},
    {23, L"スライダー"},
    {24, L"水平"},
    {25, L"スタッカート"},
    {26, L"U字"},
    {27, L"逆U字"},
    {28, L"への字"},
    {29, L"アーチ"},
    {30, L"ビブラート"},
    {39, L"ジャストヒット"},
    {40, L"エッジボイス"},
    {41, L"フォールエッジ"},
    {42, L"逆こぶし"},
}};

/// 所有者のない可視ウィンドウから、現在プロセスのDAM主要画面を探します。
BOOL CALLBACK FindMainWindowCallback(HWND window, LPARAM parameter) {
  auto* result = reinterpret_cast<HWND*>(parameter);
  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  if (process_id != GetCurrentProcessId() || !IsWindowVisible(window) ||
      GetWindow(window, GW_OWNER) != nullptr) {
    return TRUE;
  }
  *result = window;
  return FALSE;
}

/// 44個の内部IDを、ビブラートを統合した表示用IDへ変換します。
int CanonicalTechniqueId(int technique_id) {
  if (technique_id >= 30 && technique_id <= 38) {
    return 30;
  }
  return technique_id;
}

/// 表示用IDに一致する固定グリッド位置を返します。
int TechniqueIndex(int technique_id) {
  const int canonical = CanonicalTechniqueId(technique_id);
  for (size_t index = 0; index < kTechniques.size(); ++index) {
    if (kTechniques[index].id == canonical) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

/// GDI+へ渡す不透明度を0.0から1.0の範囲へ正規化します。
Gdiplus::REAL AlphaFraction(BYTE alpha) {
  return static_cast<Gdiplus::REAL>(alpha) / 255.0F;
}

/// 既存カウンターの角丸金枠に合わせた閉じた描画パスを生成します。
void BuildRoundedRectangle(Gdiplus::GraphicsPath* path,
                           const Gdiplus::RectF& bounds, float radius) {
  const float diameter = radius * 2.0F;
  path->Reset();
  path->AddArc(bounds.X, bounds.Y, diameter, diameter, 180.0F, 90.0F);
  path->AddArc(bounds.GetRight() - diameter, bounds.Y, diameter, diameter,
               270.0F, 90.0F);
  path->AddArc(bounds.GetRight() - diameter,
               bounds.GetBottom() - diameter, diameter, diameter, 0.0F,
               90.0F);
  path->AddArc(bounds.X, bounds.GetBottom() - diameter, diameter, diameter,
               90.0F, 90.0F);
  path->CloseFigure();
}

}  // namespace

/// 描画スレッド、カウンター、GDI+資源を公開クラスから隠す実装本体です。
class ScoringOverlay::Impl final {
 public:
  /// スレッド開始前の同期資源と初期カウンターを準備します。
  Impl(HINSTANCE module, std::wstring asset_directory)
      : module_(module), asset_directory_(std::move(asset_directory)) {
    InitializeCriticalSection(&data_lock_);
    counts_.fill(0);
    icons_.fill(nullptr);
    ready_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    Heartbeat();
  }

  /// 描画スレッド停止後に残る同期ハンドルを破棄します。
  ~Impl() {
    Stop();
    if (ready_event_ != nullptr) {
      CloseHandle(ready_event_);
      ready_event_ = nullptr;
    }
    DeleteCriticalSection(&data_lock_);
  }

  Impl(const Impl&) = delete;
  Impl& operator=(const Impl&) = delete;

  /// CRT初期化済みの専用スレッドを作り、ウィンドウ生成完了まで待機します。
  bool Start() {
    if (ready_event_ == nullptr) {
      return false;
    }
    unsigned int thread_id = 0;
    thread_handle_ = reinterpret_cast<HANDLE>(_beginthreadex(
        nullptr, 0, &Impl::ThreadEntry, this, 0, &thread_id));
    if (thread_handle_ == nullptr) {
      return false;
    }
    thread_id_ = thread_id;
    if (WaitForSingleObject(ready_event_, 3000) != WAIT_OBJECT_0 ||
        window_ == nullptr) {
      Stop();
      return false;
    }
    return true;
  }

  /// 曲開始時に値を初期化し、次のタイマー周期で表示させます。
  void Begin() {
    EnterCriticalSection(&data_lock_);
    counts_.fill(0);
    LeaveCriticalSection(&data_lock_);
    latest_index_.store(-1);
    session_active_.store(true);
    visible_.store(true);
    dirty_.store(true);
    Heartbeat();
    RequestRefresh();
  }

  /// 対応する技法だけを加算し、短時間の強調表示を予約します。
  void Update(int technique_id, int value) {
    if (value <= 0) {
      return;
    }
    const int index = TechniqueIndex(technique_id);
    if (index < 0) {
      return;
    }
    EnterCriticalSection(&data_lock_);
    int& count = counts_[static_cast<size_t>(index)];
    count = std::min(999, count + value);
    LeaveCriticalSection(&data_lock_);
    latest_index_.store(index);
    highlight_until_.store(GetTickCount64() + kHighlightMilliseconds);
    dirty_.store(true);
    Heartbeat();
    RequestRefresh();
  }

  /// 現在曲の値を保持したまま、透過ウィンドウの可視状態だけを変更します。
  void SetVisible(bool visible) {
    visible_.store(visible && session_active_.load());
    dirty_.store(true);
    Heartbeat();
    RequestRefresh();
  }

  /// 未検出タイルの表示設定を保存し、配置を次の描画で作り直します。
  void SetShowZero(bool show_zero) {
    show_zero_.store(show_zero);
    dirty_.store(true);
    Heartbeat();
    RequestRefresh();
  }

  /// 曲終了時に状態を閉じ、透過ウィンドウを即座に隠します。
  void End() {
    session_active_.store(false);
    visible_.store(false);
    latest_index_.store(-1);
    Heartbeat();
    RequestRefresh();
  }

  /// 最終生存時刻だけを更新し、Agentが消えた場合の自動非表示に使います。
  void Heartbeat() { last_heartbeat_.store(GetTickCount64()); }

  /// WM_CLOSEを送り、描画スレッドを最大3秒待ってからハンドルを閉じます。
  void Stop() {
    const HANDLE thread = thread_handle_;
    if (thread == nullptr) {
      return;
    }
    stopping_.store(true);
    if (window_ != nullptr) {
      PostMessageW(window_, WM_CLOSE, 0, 0);
    } else if (thread_id_ != 0) {
      PostThreadMessageW(thread_id_, WM_QUIT, 0, 0);
    }
    WaitForSingleObject(thread, 3000);
    CloseHandle(thread);
    thread_handle_ = nullptr;
    thread_id_ = 0;
  }

 private:
  /// `_beginthreadex`のC形式入口から、型付きメッセージループへ制御を移します。
  static unsigned int __stdcall ThreadEntry(void* parameter) {
    auto* self = static_cast<Impl*>(parameter);
    return self->ThreadMain();
  }

  /// GDI+と透過ウィンドウを初期化し、終了までWindowsメッセージを処理します。
  unsigned int ThreadMain() {
    Gdiplus::GdiplusStartupInput startup_input;
    if (Gdiplus::GdiplusStartup(&gdiplus_token_, &startup_input, nullptr) !=
        Gdiplus::Ok) {
      SetEvent(ready_event_);
      return 1;
    }
    LoadIcons();
    HWND owner = nullptr;
    EnumWindows(&FindMainWindowCallback, reinterpret_cast<LPARAM>(&owner));
    owner_ = owner;
    if (owner_ == nullptr || !RegisterOverlayClass()) {
      SetEvent(ready_event_);
      ReleaseGraphicsResources();
      return 1;
    }
    window_ = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE |
            WS_EX_TOOLWINDOW,
        class_name_.c_str(), L"", WS_POPUP, 0, 0, 1, 1, owner_, nullptr,
        module_, this);
    if (window_ != nullptr) {
      SetTimer(window_, kFollowTimer, kFollowIntervalMilliseconds, nullptr);
    }
    SetEvent(ready_event_);

    MSG message{};
    while (window_ != nullptr && GetMessageW(&message, nullptr, 0, 0) > 0) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    if (window_ != nullptr) {
      DestroyWindow(window_);
      window_ = nullptr;
    }
    if (!class_name_.empty()) {
      UnregisterClassW(class_name_.c_str(), module_);
    }
    ReleaseGraphicsResources();
    return 0;
  }

  /// プロセスごとに一意なクラス名を登録し、再接続時の衝突を避けます。
  bool RegisterOverlayClass() {
    class_name_ = L"DAMforWindowsTools.ScoringOverlay." +
                  std::to_wstring(GetCurrentProcessId()) + L"." +
                  std::to_wstring(GetCurrentThreadId());
    WNDCLASSEXW window_class{};
    window_class.cbSize = sizeof(window_class);
    window_class.hInstance = module_;
    window_class.lpfnWndProc = &Impl::WindowProcedure;
    window_class.lpszClassName = class_name_.c_str();
    window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    return RegisterClassExW(&window_class) != 0;
  }

  /// CreateWindowで渡した実装ポインターを保存し、対象メッセージを処理します。
  static LRESULT CALLBACK WindowProcedure(HWND window, UINT message,
                                          WPARAM wparam, LPARAM lparam) {
    Impl* self = reinterpret_cast<Impl*>(
        GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
      self = static_cast<Impl*>(create->lpCreateParams);
      SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(self));
    }
    if (self != nullptr) {
      return self->HandleMessage(window, message, wparam, lparam);
    }
    return DefWindowProcW(window, message, wparam, lparam);
  }

  /// 追従タイマー、更新要求、終了、クリック透過だけを専用ウィンドウで処理します。
  LRESULT HandleMessage(HWND window, UINT message, WPARAM wparam,
                        LPARAM lparam) {
    switch (message) {
      case WM_TIMER:
        if (wparam == kFollowTimer) {
          UpdateWindowState();
          return 0;
        }
        break;
      case kRefreshMessage:
        UpdateWindowState();
        return 0;
      case WM_NCHITTEST:
        return HTTRANSPARENT;
      case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
      case WM_CLOSE:
        KillTimer(window, kFollowTimer);
        DestroyWindow(window);
        return 0;
      case WM_DESTROY:
        window_ = nullptr;
        PostQuitMessage(0);
        return 0;
      default:
        break;
    }
    return DefWindowProcW(window, message, wparam, lparam);
  }

  /// DAMの現在クライアント座標へ追従し、必要なフレームだけを再描画します。
  void UpdateWindowState() {
    if (window_ == nullptr || owner_ == nullptr || !IsWindow(owner_)) {
      return;
    }
    const ULONGLONG now = GetTickCount64();
    if (now - last_heartbeat_.load() > kHeartbeatTimeoutMilliseconds) {
      visible_.store(false);
    }
    if (!session_active_.load() || !visible_.load() || stopping_.load() ||
        !IsWindowVisible(owner_) || IsIconic(owner_)) {
      ShowWindow(window_, SW_HIDE);
      return;
    }
    RECT client{};
    if (!GetClientRect(owner_, &client)) {
      ShowWindow(window_, SW_HIDE);
      return;
    }
    POINT origin{client.left, client.top};
    if (!ClientToScreen(owner_, &origin)) {
      ShowWindow(window_, SW_HIDE);
      return;
    }
    const int width = client.right - client.left;
    const int height = client.bottom - client.top;
    const bool highlight_expired =
        latest_index_.load() >= 0 && now >= highlight_until_.load();
    if (highlight_expired) {
      latest_index_.store(-1);
      dirty_.store(true);
    }
    if (width != last_width_ || height != last_height_) {
      last_width_ = width;
      last_height_ = height;
      dirty_.store(true);
    }
    SetWindowPos(window_, HWND_TOP, origin.x, origin.y, width, height,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
    if (dirty_.exchange(false)) {
      Render(origin, width, height);
    }
  }

  /// 全技法アイコンをID別ファイル名から読み込み、不足時も文字表示を継続します。
  void LoadIcons() {
    for (size_t index = 0; index < kTechniques.size(); ++index) {
      wchar_t filename[32]{};
      swprintf_s(filename, L"technique_%02d.png", kTechniques[index].id);
      std::wstring path = asset_directory_;
      if (!path.empty() && path.back() != L'\\' && path.back() != L'/') {
        path.push_back(L'\\');
      }
      path.append(filename);
      Gdiplus::Image* image = new Gdiplus::Image(path.c_str());
      if (image != nullptr && image->GetLastStatus() == Gdiplus::Ok) {
        icons_[index] = image;
      } else {
        delete image;
      }
    }
  }

  /// 読み込んだ画像とGDI+トークンを描画スレッド内で解放します。
  void ReleaseGraphicsResources() {
    for (Gdiplus::Image*& image : icons_) {
      delete image;
      image = nullptr;
    }
    if (gdiplus_token_ != 0) {
      Gdiplus::GdiplusShutdown(gdiplus_token_);
      gdiplus_token_ = 0;
    }
  }

  /// 透明DIBへ全タイルを描き、所有ウィンドウ上の1枚のレイヤーとして更新します。
  void Render(POINT origin, int width, int height) {
    if (width <= 0 || height <= 0) {
      return;
    }
    HDC screen = GetDC(nullptr);
    if (screen == nullptr) {
      return;
    }
    HDC memory = CreateCompatibleDC(screen);
    if (memory == nullptr) {
      ReleaseDC(nullptr, screen);
      return;
    }
    BITMAPINFO bitmap_info{};
    bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = width;
    bitmap_info.bmiHeader.biHeight = -height;
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr;
    HBITMAP bitmap = CreateDIBSection(screen, &bitmap_info, DIB_RGB_COLORS,
                                      &pixels, nullptr, 0);
    if (bitmap == nullptr || pixels == nullptr) {
      if (bitmap != nullptr) {
        DeleteObject(bitmap);
      }
      DeleteDC(memory);
      ReleaseDC(nullptr, screen);
      return;
    }
    const HGDIOBJ previous_bitmap = SelectObject(memory, bitmap);
    std::array<int, kTechniques.size()> counts{};
    EnterCriticalSection(&data_lock_);
    counts = counts_;
    LeaveCriticalSection(&data_lock_);

    Gdiplus::Graphics graphics(memory);
    graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    DrawGrid(graphics, counts, width, height);

    POINT source_origin{0, 0};
    SIZE size{width, height};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(window_, screen, &origin, &size, memory,
                        &source_origin, 0, &blend, ULW_ALPHA);
    SelectObject(memory, previous_bitmap);
    DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
  }

  /// 1920x1080基準の固定比率で、歌詞とAI感性表示を避けた5行グリッドを配置します。
  void DrawGrid(Gdiplus::Graphics& graphics,
                const std::array<int, kTechniques.size()>& counts, int width,
                int height) {
    const float scale = std::max(
        0.5F, std::min(static_cast<float>(width) / kReferenceWidth,
                       static_cast<float>(height) / kReferenceHeight));
    const float left = 14.0F * scale;
    const float top = 366.0F * scale;
    const float grid_width = 1410.0F * scale;
    const float gap = 6.0F * scale;
    const float tile_height = 43.0F * scale;
    const float tile_width =
        (grid_width - gap * static_cast<float>(kColumnCount - 1)) /
        static_cast<float>(kColumnCount);
    size_t visible_index = 0;
    const bool show_zero = show_zero_.load();
    for (size_t index = 0; index < kTechniques.size(); ++index) {
      if (!show_zero && counts[index] == 0) {
        continue;
      }
      const int row = static_cast<int>(visible_index) / kColumnCount;
      const int column = static_cast<int>(visible_index) % kColumnCount;
      const Gdiplus::RectF bounds(
          left + static_cast<float>(column) * (tile_width + gap),
          top + static_cast<float>(row) * (tile_height + gap), tile_width,
          tile_height);
      DrawTechnique(graphics, index, counts[index], bounds, scale);
      ++visible_index;
    }
  }

  /// 既存MusicStaffの暗色面・金枠・白文字・右寄せ回数を1タイルへ描きます。
  void DrawTechnique(Gdiplus::Graphics& graphics, size_t index, int count,
                     const Gdiplus::RectF& bounds, float scale) {
    const bool detected = count > 0;
    const bool latest = latest_index_.load() == static_cast<int>(index);
    const BYTE content_alpha = detected ? 255 : 112;
    const BYTE border_alpha = latest ? 255 : (detected ? 235 : 105);
    Gdiplus::GraphicsPath tile_path;
    BuildRoundedRectangle(&tile_path, bounds, 5.0F * scale);
    Gdiplus::LinearGradientBrush background(
        Gdiplus::PointF(bounds.X, bounds.Y),
        Gdiplus::PointF(bounds.X, bounds.GetBottom()),
        Gdiplus::Color(255, detected ? 55 : 38, detected ? 60 : 42,
                       detected ? 61 : 44),
        Gdiplus::Color(255, 7, 10, 14));
    graphics.FillPath(&background, &tile_path);
    if (latest) {
      Gdiplus::Pen glow(Gdiplus::Color(150, 255, 215, 92), 4.0F * scale);
      graphics.DrawPath(&glow, &tile_path);
    }
    Gdiplus::Pen border(
        Gdiplus::Color(border_alpha, latest ? 255 : 201,
                       latest ? 226 : 174, latest ? 118 : 73),
        latest ? 2.2F * scale : 1.2F * scale);
    graphics.DrawPath(&border, &tile_path);

    const float icon_width = 38.0F * scale;
    const float icon_height = 22.0F * scale;
    const Gdiplus::RectF icon_bounds(
        bounds.X + 8.0F * scale,
        bounds.Y + (bounds.Height - icon_height) * 0.5F, icon_width,
        icon_height);
    DrawIcon(graphics, index, icon_bounds, content_alpha);

    const float count_width = 32.0F * scale;
    const float divider_x = bounds.GetRight() - count_width;
    Gdiplus::Pen divider(Gdiplus::Color(border_alpha / 2, 220, 205, 156),
                         1.0F * scale);
    graphics.DrawLine(&divider, divider_x, bounds.Y + 6.0F * scale,
                      divider_x, bounds.GetBottom() - 6.0F * scale);

    const size_t name_length = std::wcslen(kTechniques[index].name);
    const float name_size =
        (name_length >= 11 ? 10.0F : (name_length >= 8 ? 11.0F : 12.5F)) *
        scale;
    Gdiplus::FontFamily japanese_family(L"Yu Gothic UI");
    Gdiplus::Font name_font(&japanese_family, name_size,
                            Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush shadow(Gdiplus::Color(content_alpha, 0, 0, 0));
    Gdiplus::SolidBrush text(
        Gdiplus::Color(content_alpha, 244, 242, 235));
    Gdiplus::StringFormat name_format(Gdiplus::StringFormat::GenericTypographic());
    name_format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    name_format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
    const Gdiplus::RectF name_bounds(
        icon_bounds.GetRight() + 6.0F * scale, bounds.Y,
        std::max(1.0F, divider_x - icon_bounds.GetRight() - 10.0F * scale),
        bounds.Height);
    Gdiplus::RectF shadow_bounds = name_bounds;
    shadow_bounds.X += 1.0F * scale;
    shadow_bounds.Y += 1.0F * scale;
    graphics.DrawString(kTechniques[index].name, -1, &name_font,
                        shadow_bounds, &name_format, &shadow);
    graphics.DrawString(kTechniques[index].name, -1, &name_font, name_bounds,
                        &name_format, &text);

    wchar_t count_text[8]{};
    swprintf_s(count_text, L"%d", count);
    Gdiplus::FontFamily number_family(L"Arial");
    Gdiplus::Font number_font(&number_family, 18.0F * scale,
                              Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::StringFormat number_format;
    number_format.SetAlignment(Gdiplus::StringAlignmentCenter);
    number_format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    const Gdiplus::RectF number_bounds(divider_x, bounds.Y, count_width,
                                       bounds.Height);
    Gdiplus::SolidBrush number_brush(
        Gdiplus::Color(content_alpha, 255, 255, 255));
    graphics.DrawString(count_text, -1, &number_font, number_bounds,
                        &number_format, &number_brush);
  }

  /// PNGの透明度を未検知時だけ下げ、画像がなければ短い金線を代替表示します。
  void DrawIcon(Gdiplus::Graphics& graphics, size_t index,
                const Gdiplus::RectF& bounds, BYTE alpha) {
    Gdiplus::Image* image = icons_[index];
    if (image == nullptr) {
      Gdiplus::Pen fallback(Gdiplus::Color(alpha, 230, 190, 80),
                            2.0F);
      graphics.DrawLine(&fallback, bounds.X, bounds.GetBottom(),
                        bounds.GetRight(), bounds.Y);
      return;
    }
    Gdiplus::ColorMatrix matrix{{
        {1.0F, 0.0F, 0.0F, 0.0F, 0.0F},
        {0.0F, 1.0F, 0.0F, 0.0F, 0.0F},
        {0.0F, 0.0F, 1.0F, 0.0F, 0.0F},
        {0.0F, 0.0F, 0.0F, AlphaFraction(alpha), 0.0F},
        {0.0F, 0.0F, 0.0F, 0.0F, 1.0F},
    }};
    Gdiplus::ImageAttributes attributes;
    attributes.SetColorMatrix(&matrix, Gdiplus::ColorMatrixFlagsDefault,
                              Gdiplus::ColorAdjustTypeBitmap);
    graphics.DrawImage(
        image, bounds, 0.0F, 0.0F,
        static_cast<Gdiplus::REAL>(image->GetWidth()),
        static_cast<Gdiplus::REAL>(image->GetHeight()), Gdiplus::UnitPixel,
        &attributes);
  }

  /// 描画ウィンドウが生成済みなら、専用更新メッセージを非同期送信します。
  void RequestRefresh() {
    const HWND window = window_;
    if (window != nullptr) {
      PostMessageW(window, kRefreshMessage, 0, 0);
    }
  }

  HINSTANCE module_ = nullptr;
  std::wstring asset_directory_;
  std::wstring class_name_;
  HWND owner_ = nullptr;
  HWND window_ = nullptr;
  HANDLE thread_handle_ = nullptr;
  HANDLE ready_event_ = nullptr;
  unsigned int thread_id_ = 0;
  ULONG_PTR gdiplus_token_ = 0;
  CRITICAL_SECTION data_lock_{};
  std::array<int, kTechniques.size()> counts_{};
  std::array<Gdiplus::Image*, kTechniques.size()> icons_{};
  std::atomic<bool> session_active_{false};
  std::atomic<bool> visible_{false};
  std::atomic<bool> show_zero_{true};
  std::atomic<bool> dirty_{true};
  std::atomic<bool> stopping_{false};
  std::atomic<int> latest_index_{-1};
  std::atomic<ULONGLONG> highlight_until_{0};
  std::atomic<ULONGLONG> last_heartbeat_{0};
  int last_width_ = 0;
  int last_height_ = 0;
};

/// 実装本体を例外なしで確保し、公開クラスの寿命へ結び付けます。
ScoringOverlay::ScoringOverlay(HINSTANCE module,
                               std::wstring asset_directory)
    : impl_(new (std::nothrow)
                Impl(module, std::move(asset_directory))) {}

/// DLL停止時にメッセージループと同期資源を確実に破棄します。
ScoringOverlay::~ScoringOverlay() { delete impl_; }

/// 実装が確保できた場合だけ描画スレッドを開始します。
bool ScoringOverlay::Start() { return impl_ != nullptr && impl_->Start(); }

/// 新しい曲の表示開始を描画実装へ渡します。
void ScoringOverlay::Begin() {
  if (impl_ != nullptr) {
    impl_->Begin();
  }
}

/// 技法IDと増分を描画実装へ渡します。
void ScoringOverlay::Update(int technique_id, int value) {
  if (impl_ != nullptr) {
    impl_->Update(technique_id, value);
  }
}

/// 回数を保持したまま、現在曲の表示だけを切り替えます。
void ScoringOverlay::SetVisible(bool visible) {
  if (impl_ != nullptr) {
    impl_->SetVisible(visible);
  }
}

/// 未検出タイルを含める設定を描画実装へ渡します。
void ScoringOverlay::SetShowZero(bool show_zero) {
  if (impl_ != nullptr) {
    impl_->SetShowZero(show_zero);
  }
}

/// 曲終了を描画実装へ渡します。
void ScoringOverlay::End() {
  if (impl_ != nullptr) {
    impl_->End();
  }
}

/// Agent生存通知を描画実装へ渡します。
void ScoringOverlay::Heartbeat() {
  if (impl_ != nullptr) {
    impl_->Heartbeat();
  }
}

/// 明示終了を描画実装へ渡します。
void ScoringOverlay::Stop() {
  if (impl_ != nullptr) {
    impl_->Stop();
  }
}
