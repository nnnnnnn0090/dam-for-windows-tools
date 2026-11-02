// Project: DAM for Windows Tools
// File: agent_session.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import fs from 'node:fs';
import path from 'node:path';

import * as frida from 'frida';

import { agentFragmentNames, composeAgentSource } from './agent_source.js';
import { normalizeConfig } from './helper_config.js';
import { findTarget, sha256 } from './target_discovery.js';

/** 対象DAMの検証、Frida接続、Agent寿命、URL準備待機を一括管理します。 */
export class AgentSession {
  /** 対応構成と通知先を受け取り、未接続セッションを生成します。 */
  constructor({ helperDirectory, targetConfiguration, protocol }) {
    this.helperDirectory = helperDirectory;
    this.targetConfiguration = targetConfiguration;
    this.protocol = protocol;
    this.currentConfig = normalizeConfig({});
    this.session = null;
    this.script = null;
    this.attachedPid = null;
    this.attaching = false;
    this.shuttingDown = false;
    this.pendingPreparations = new Map();
  }

  /**
   * 対象プロセスとSHA-256を検証し、一致したDAMだけへAgentを接続します。
   * 接続途中の失敗では、適用済みパッチの復元とセッション解放を必ず試行します。
   */
  async ensureAttached() {
    if (this.shuttingDown || this.attaching || this.session) return;
    this.attaching = true;
    let activeSession = null;
    let activeScript = null;
    const {
      manifest,
      processName,
      runtimeConfig,
      supportedHash,
      targetLabel,
    } = this.targetConfiguration;
    try {
      const target = await findTarget(processName);
      if (!target) {
        this.protocol.status('waiting', `${processName} の起動を待っています`);
        return;
      }
      const executablePath = target.parameters && target.parameters.path;
      if (!executablePath || !fs.existsSync(executablePath)) {
        this.protocol.status('unsupported', 'DAM実行ファイルのパスを確認できません');
        return;
      }
      const actualHash = await sha256(executablePath);
      if (actualHash !== supportedHash) {
        this.protocol.status(
          'unsupported',
          `未対応のDAMです。${targetLabel}のSHA-256と一致しません (${actualHash.slice(0, 12)}…)`,
        );
        return;
      }

      this.protocol.status('attaching', `${targetLabel} (PID ${target.pid}) へ接続中`);
      activeSession = await frida.attach(target.pid);
      activeScript = await activeSession.createScript(
        this.#composeSource(manifest, runtimeConfig),
        { name: 'dam-for-windows-tools-agent' },
      );
      activeScript.message.connect((message) => this.#handleAgentMessage(message));
      activeSession.detached.connect((reason) => {
        if (this.session === activeSession) {
          this.session = null;
          this.script = null;
          this.attachedPid = null;
          this.protocol.status('waiting', `DAMから切断されました: ${reason}`);
        }
      });
      await activeScript.load();
      await activeScript.exports.initialize(this.currentConfig);
      this.session = activeSession;
      this.script = activeScript;
      this.attachedPid = target.pid;
      this.protocol.status('attached', `${targetLabel} 接続済み (PID ${target.pid})`);
    } catch (error) {
      this.protocol.status('attach-error', `DAM接続失敗: ${error.message || error}`);
      if (activeScript) {
        try {
          await activeScript.exports.restoreAll();
        } catch (_) {}
        try {
          await activeScript.unload();
        } catch (_) {}
      }
      if (activeSession) {
        try {
          await activeSession.detach();
        } catch (_) {}
      }
      await this.detach();
    } finally {
      this.attaching = false;
    }
  }

  /** 最新の機能設定を保持し、接続済みAgentへ即時反映します。 */
  async updateConfig(command) {
    this.currentConfig = normalizeConfig(command);
    if (this.script) await this.script.exports.updateConfig(this.currentConfig);
  }

  /** Flutterから届いたローカルURL登録結果を、待機中のFridaメッセージへ返します。 */
  respondToPreparation(command) {
    if (!this.script || !command.requestId) return;
    const requestId = String(command.requestId);
    const timer = this.pendingPreparations.get(requestId);
    if (!timer) return;
    clearTimeout(timer);
    this.pendingPreparations.delete(requestId);
    this.script.post({
      type: `prepare-result:${requestId}`,
      payload: {
        accepted: command.accepted === true,
        localUrl: String(command.localUrl || ''),
        error: String(command.error || ''),
      },
    });
  }

  /** 現在接続を安全に切断してから、対象DAMを再探索します。 */
  async reconnect() {
    await this.detach();
    await this.ensureAttached();
  }

  /** パッチ復元、Agent破棄、Frida切断の順で接続資源を解放します。 */
  async detach() {
    const activeScript = this.script;
    const activeSession = this.session;
    this.script = null;
    this.session = null;
    this.attachedPid = null;
    for (const timer of this.pendingPreparations.values()) clearTimeout(timer);
    this.pendingPreparations.clear();
    if (activeScript) {
      try {
        await activeScript.exports.restoreAll();
      } catch (_) {
        // DAMが既に終了している場合は復元先がないため、そのまま解放を続けます。
      }
      try {
        await activeScript.unload();
      } catch (_) {}
    }
    if (activeSession) {
      try {
        await activeSession.detach();
      } catch (_) {}
    }
  }

  /** 順序固定フラグメントと対象マニフェストから、今回注入するAgentソースを構築します。 */
  #composeSource(manifest, runtimeConfig) {
    const identitySource = fs.readFileSync(
      path.join(this.helperDirectory, 'identity.js'),
      'utf8',
    );
    const agentSources = agentFragmentNames.map((filename) =>
      fs.readFileSync(
        path.join(this.helperDirectory, 'agent', filename),
        'utf8',
      ),
    );
    return composeAgentSource({
      manifest,
      runtimeConfig,
      identitySource,
      agentSources,
    });
  }

  /** Fridaメッセージを検証し、Flutterへ公開するイベントだけを型別に転送します。 */
  #handleAgentMessage(message) {
    if (message.type === 'error') {
      this.protocol.log(`Frida agent error: ${message.description || 'unknown error'}`);
      return;
    }
    if (message.type !== 'send') return;
    const payload = message.payload;
    if (!payload || typeof payload !== 'object') return;
    switch (payload.type) {
      case 'log':
        this.protocol.log(payload.message || '');
        break;
      case 'patch-error':
        this.protocol.emit({ type: 'patch-error', message: String(payload.message || '') });
        break;
      case 'metadata':
        this.protocol.emit({ type: 'metadata', candidates: payload.candidates || [] });
        break;
      case 'playback':
      case 'rewritten':
      case 'scoring-start':
      case 'scoring-technique':
      case 'scoring-stop':
      case 'remote-search-result':
      case 'remote-detail-result':
      case 'remote-reserve-result':
      case 'remote-favorite-result':
        this.protocol.emit(payload);
        break;
      case 'prepare':
        this.#beginPreparation(payload);
        break;
      default:
        this.protocol.log(`未処理のAgentイベント: ${payload.type || 'unknown'}`);
    }
  }

  /** URL登録要求をFlutterへ渡し、1.9秒以内に応答がなければ公式URL利用へ戻します。 */
  #beginPreparation(payload) {
    const requestId = String(payload.requestId || '');
    if (!requestId) return;
    this.protocol.emit(payload);
    const timer = setTimeout(() => {
      this.pendingPreparations.delete(requestId);
      if (this.script) {
        this.script.post({
          type: `prepare-result:${requestId}`,
          payload: {
            accepted: false,
            localUrl: '',
            error: 'registration timeout',
          },
        });
      }
    }, 1900);
    this.pendingPreparations.set(requestId, timer);
  }
}
