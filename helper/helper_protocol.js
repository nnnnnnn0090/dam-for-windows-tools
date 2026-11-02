// Project: DAM for Windows Tools
// File: helper_protocol.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import readline from 'node:readline';

/** Flutterとの標準入出力を、上限付きJSON Linesプロトコルとして管理します。 */
export class HelperProtocol {
  static maxCommandLineLength = 64 * 1024;

  #lastStatusKey = '';

  /** 1つの値をJSONへ符号化し、標準出力へ改行区切りで送信します。 */
  emit(value) {
    process.stdout.write(`${JSON.stringify(value)}\n`);
  }

  /** 診断メッセージを型付きイベントとしてFlutterへ送信します。 */
  log(message) {
    this.emit({ type: 'log', message: String(message) });
  }

  /** 同じ状態通知の連続送信を抑え、変化した接続状態だけを通知します。 */
  status(state, detail) {
    const normalizedDetail = String(detail || '');
    const key = `${state}\n${normalizedDetail}`;
    if (key === this.#lastStatusKey) return;
    this.#lastStatusKey = key;
    this.emit({ type: 'status', state, detail: normalizedDetail });
  }

  /** 標準入力と終了シグナルを監視し、不正・巨大コマンドを処理前に拒否します。 */
  listen(handleCommand, shutdown) {
    const input = readline.createInterface({ input: process.stdin });
    input.on('line', (line) => {
      if (line.length > HelperProtocol.maxCommandLineLength) {
        this.log('上限を超えるJSON Linesコマンドを拒否しました');
        return;
      }
      try {
        const command = JSON.parse(line);
        Promise.resolve(handleCommand(command)).catch((error) => {
          this.log(`コマンド処理失敗: ${error.message || error}`);
        });
      } catch (_) {
        this.log('不正なJSON Linesコマンドを拒否しました');
      }
    });
    input.on('close', shutdown);
    process.on('SIGINT', shutdown);
    process.on('SIGTERM', shutdown);
    process.on('uncaughtException', (error) => {
      this.log(`ヘルパー例外: ${error.message || error}`);
    });
    process.on('unhandledRejection', (error) => {
      this.log(`ヘルパー非同期例外: ${error && error.message ? error.message : error}`);
    });
  }
}
