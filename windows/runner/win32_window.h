// Project: DAM for Windows Tools
// File: win32_window.h
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

/// 高DPI対応のWin32トップレベルウィンドウを抽象化します。
///
/// 描画や入力を追加する派生クラスが、ハンドル管理と共通メッセージ処理を
/// 再実装しなくてよいようにします。
class Win32Window {
 public:
  /// ウィンドウ左上の論理座標を表します。
  struct Point {
    unsigned int x;
    unsigned int y;
    /// X・Y座標から位置を生成します。
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  /// ウィンドウの論理幅と高さを表します。
  struct Size {
    unsigned int width;
    unsigned int height;
    /// 幅と高さからサイズを生成します。
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  /// 未作成のウィンドウを生成し、アクティブ数へ登録します。
  Win32Window();
  /// OS資源を破棄し、アクティブ数から登録解除します。
  virtual ~Win32Window();

  /// 既定モニターのDPIで論理位置・サイズを物理ピクセルへ変換し、非表示で作成します。
  /// [Show]が呼ばれるまで表示せず、作成と派生初期化が成功した場合だけtrueを返します。
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  /// 現在のウィンドウを通常状態で表示し、成功したか返します。
  bool Show();

  /// 子クラスの終了処理後に、関連するOSウィンドウ資源を解放します。
  void Destroy();

  /// 指定HWNDを子ウィンドウとして組み込み、クライアント領域へ合わせます。
  void SetChildContent(HWND content);

  /// アイコンなどの設定に使うHWNDを返し、破棄済みならnullptrを返します。
  HWND GetHandle();

  /// ウィンドウ破棄時にアプリのメッセージループも終了するか設定します。
  void SetQuitOnClose(bool quit_on_close);

  /// 現在のクライアント領域をRECTとして返します。
  RECT GetClientArea();

 protected:
  /// DPI・サイズ・フォーカス・テーマの共通メッセージを処理し、残りをOSへ委譲します。
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  /// HWND作成後に派生クラス固有の初期化を行い、失敗時はfalseを返します。
  virtual bool OnCreate();

  /// HWND破棄前に派生クラス固有の解放処理を行います。
  virtual void OnDestroy();

 private:
  friend class WindowClassRegistrar;

  /// OSメッセージ入口でWM_NCCREATE時にインスタンスとDPI処理を関連付けます。
  /// 以後のメッセージは対応する[Win32Window]の[MessageHandler]へ転送します。
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  /// HWNDのユーザーデータから対応するクラスインスタンスを取得します。
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  /// Windowsのアプリテーマ設定に合わせてウィンドウ枠の暗色表示を更新します。
  static void UpdateTheme(HWND const window);

  bool quit_on_close_ = false;

  // トップレベルウィンドウのハンドルです。
  HWND window_handle_ = nullptr;

  // 組み込んだFlutter子ウィンドウのハンドルです。
  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_ の終端
