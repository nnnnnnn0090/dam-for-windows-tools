// Project: DAM for Windows Tools
// File: main.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { AgentSession } from './agent_session.js';
import { CommandRouter } from './command_router.js';
import { HelperProtocol } from './helper_protocol.js';
import { loadTargetConfiguration } from './target_config.js';

const helperDirectory = path.dirname(fileURLToPath(import.meta.url));
const protocol = new HelperProtocol();
const agentSession = new AgentSession({
  helperDirectory,
  targetConfiguration: loadTargetConfiguration(helperDirectory),
  protocol,
});

let shuttingDown = false;
/** 多重終了を防ぎ、パッチ復元とFrida切断を完了してからプロセスを終了します。 */
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  agentSession.shuttingDown = true;
  await agentSession.detach();
  process.exit(0);
}

const commands = new CommandRouter({ agentSession, protocol, shutdown });
protocol.listen((command) => commands.handle(command), shutdown);
protocol.status('ready', 'Fridaヘルパー起動済み');

setInterval(() => {
  agentSession.ensureAttached().catch((error) => {
    protocol.log(`監視失敗: ${error.message || error}`);
  });
}, 750).unref();

await agentSession.ensureAttached();
