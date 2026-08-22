// Project: DAM for Windows Tools
// File: command_router.test.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import assert from 'node:assert/strict';
import test from 'node:test';

import { CommandRouter } from '../command_router.js';

/** 送信イベントとAgent RPC呼出を記録できる、コマンドルーター用テスト構成を生成します。 */
function fixture(script = null) {
  const emitted = [];
  const logs = [];
  const agentSession = {
    script,
    async updateConfig(command) { this.config = command; },
    respondToPreparation(command) { this.preparation = command; },
    async reconnect() { this.reconnected = true; },
  };
  const protocol = {
    emit(value) { emitted.push(value); },
    log(value) { logs.push(value); },
  };
  const router = new CommandRouter({
    agentSession,
    protocol,
    shutdown: async () => {},
  });
  return { agentSession, emitted, logs, router };
}

// DAM未接続でも相関ID付きエラー応答が返ることを検証します。
test('returns a correlated error when DAM is disconnected', async () => {
  const { emitted, router } = fixture();
  await router.handle({ type: 'remoteState', requestId: 'request-1' });
  assert.deepEqual(emitted, [{
    type: 'remote-state-result',
    requestId: 'request-1',
    error: 'DAMに接続されていません',
  }]);
});

// 各リモコンコマンドが接続中Agentの対応RPCへ渡ることを検証します。
test('forwards remote commands to the current agent script', async () => {
  const calls = [];
  const script = {
    exports: {
      async remoteSearch(...values) { calls.push(values); },
      async remoteState() { return { connected: true }; },
    },
  };
  const { emitted, router } = fixture(script);
  await router.handle({
    type: 'remoteSearch',
    requestId: 'request-2',
    query: 'Lemon',
    mode: 'title',
  });
  await router.handle({ type: 'remoteState', requestId: 'request-3' });
  assert.deepEqual(calls, [['request-2', 'Lemon', 'title']]);
  assert.deepEqual(emitted, [{
    type: 'remote-state-result',
    requestId: 'request-3',
    result: { connected: true },
  }]);
});
