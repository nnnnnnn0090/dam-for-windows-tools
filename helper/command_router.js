// Project: DAM for Windows Tools
// File: command_router.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

const commandResultTypes = Object.freeze({
  remoteState: 'remote-state-result',
  remoteControl: 'remote-control-result',
  remoteQueue: 'remote-queue-result',
  remoteQueueAction: 'remote-queue-action-result',
});

/** 任意の例外値から、プロトコルへ安全に載せられる短い文字列を取得します。 */
function errorText(error) {
  return String(error && error.message ? error.message : error);
}

/** Flutterから許可されたコマンドを、接続中Agentの対応RPCへ振り分けます。 */
export class CommandRouter {
  /** Agentセッション、出力プロトコル、終了処理を明示的に受け取ります。 */
  constructor({ agentSession, protocol, shutdown }) {
    this.agentSession = agentSession;
    this.protocol = protocol;
    this.shutdown = shutdown;
  }

  /** コマンド種別を許可リストで分岐し、未知の要求は実行せずログへ残します。 */
  async handle(command) {
    switch (command.type) {
      case 'config':
        await this.agentSession.updateConfig(command);
        break;
      case 'prepareResult':
        this.agentSession.respondToPreparation(command);
        break;
      case 'reconnect':
        await this.agentSession.reconnect();
        break;
      case 'remoteSearch':
        await this.#remoteSearch(command);
        break;
      case 'remoteDetail':
        await this.#remoteDetail(command);
        break;
      case 'remoteReserve':
        await this.#remoteReserve(command);
        break;
      case 'remoteFavorite':
        await this.#remoteFavorite(command);
        break;
      case 'remoteState':
      case 'remoteControl':
      case 'remoteQueue':
      case 'remoteQueueAction':
        await this.#remoteCommand(command);
        break;
      case 'shutdown':
        await this.shutdown();
        break;
      default:
        this.protocol.log(`不明なヘルパーコマンド: ${command.type || 'unknown'}`);
    }
  }

  /** 検索要求をAgentへ転送し、未接続・RPC失敗時も相関ID付き結果を返します。 */
  async #remoteSearch(command) {
    const requestId = String(command.requestId || '');
    const query = String(command.query || '');
    const mode = String(command.mode || 'keyword');
    const script = this.agentSession.script;
    if (!script) {
      this.protocol.emit({
        type: 'remote-search-result',
        requestId,
        query,
        total: 0,
        rows: [],
        error: 'DAMに接続されていません',
      });
      return;
    }
    try {
      await script.exports.remoteSearch(requestId, query, mode);
    } catch (error) {
      this.protocol.emit({
        type: 'remote-search-result',
        requestId,
        query,
        mode,
        total: 0,
        rows: [],
        error: errorText(error),
      });
    }
  }

  /** 曲詳細要求をAgentへ転送し、応答待機が残らないよう失敗も結果化します。 */
  async #remoteDetail(command) {
    const requestId = String(command.requestId || '');
    const script = this.agentSession.script;
    if (!script) {
      this.protocol.emit({
        type: 'remote-detail-result',
        requestId,
        error: 'DAMに接続されていません',
      });
      return;
    }
    try {
      await script.exports.remoteDetail(
        requestId,
        String(command.token || ''),
      );
    } catch (error) {
      this.protocol.emit({
        type: 'remote-detail-result',
        requestId,
        error: errorText(error),
      });
    }
  }

  /** 予約条件を明示的な値へ変換してAgentへ渡し、受理可否を返します。 */
  async #remoteReserve(command) {
    const requestId = String(command.requestId || '');
    const script = this.agentSession.script;
    if (!script) {
      this.protocol.emit({
        type: 'remote-reserve-result',
        requestId,
        accepted: false,
        message: 'DAMに接続されていません',
      });
      return;
    }
    try {
      await script.exports.remoteReserve(
        requestId,
        String(command.token || ''),
        {
          mode: String(command.mode || 'normal'),
          key: Number(command.key || 0),
          scoring: command.scoring === true,
          playType: String(command.playType || 'standard'),
        },
      );
    } catch (error) {
      this.protocol.emit({
        type: 'remote-reserve-result',
        requestId,
        accepted: false,
        message: errorText(error),
      });
    }
  }

  /** お気に入り登録・解除をAgentへ転送し、変更後状態を返します。 */
  async #remoteFavorite(command) {
    const requestId = String(command.requestId || '');
    const script = this.agentSession.script;
    if (!script) {
      this.protocol.emit({
        type: 'remote-favorite-result',
        requestId,
        accepted: false,
        favorite: false,
        message: 'DAMに接続されていません',
      });
      return;
    }
    try {
      await script.exports.remoteFavorite(
        requestId,
        String(command.token || ''),
        command.action === 'remove' ? 'remove' : 'add',
      );
    } catch (error) {
      this.protocol.emit({
        type: 'remote-favorite-result',
        requestId,
        accepted: false,
        favorite: command.action !== 'remove',
        message: errorText(error),
      });
    }
  }

  /** 状態・演奏・予約一覧の同期RPCを共通経路で呼び、型別応答を返します。 */
  async #remoteCommand(command) {
    const requestId = String(command.requestId || '');
    const resultType = commandResultTypes[command.type];
    const script = this.agentSession.script;
    if (!script) {
      this.protocol.emit({
        type: resultType,
        requestId,
        error: 'DAMに接続されていません',
      });
      return;
    }
    try {
      let result;
      if (command.type === 'remoteState') {
        result = await script.exports.remoteState();
      } else if (command.type === 'remoteControl') {
        result = await script.exports.remoteControl(
          String(command.action || ''),
        );
      } else if (command.type === 'remoteQueue') {
        result = await script.exports.remoteQueue();
      } else {
        result = await script.exports.remoteQueueAction(
          String(command.action || ''),
          String(command.token || ''),
        );
      }
      this.protocol.emit({ type: resultType, requestId, result });
    } catch (error) {
      this.protocol.emit({
        type: resultType,
        requestId,
        error: errorText(error),
      });
    }
  }
}
