// Project: DAM for Windows Tools
// File: utils.h
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

/// デバッグ用コンソールを作り、RunnerとFlutterの標準出力・標準エラーを接続します。
void CreateAndAttachConsole();

/// NULL終端UTF-16を上限付きでUTF-8へ変換し、失敗時は空文字列を返します。
std::string Utf8FromUtf16(const wchar_t* utf16_string);

/// 実行ファイル名を除くコマンドライン引数をUTF-8文字列一覧として返します。
std::vector<std::string> GetCommandLineArguments();

#endif  // RUNNER_UTILS_H_ の終端
