// Project: DAM for Windows Tools
// File: main.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

import * as frida from 'frida';
import { composeAgentSource } from './agent_source.js';
import { loadTargetConfiguration } from './target_config.js';

const helperDirectory = path.dirname(fileURLToPath(import.meta.url));
const targetConfiguration = loadTargetConfiguration(helperDirectory);
const {
  manifest,
  processName,
  runtimeConfig,
  supportedHash,
  targetLabel,
} = targetConfiguration;
const maxCommandLineLength = 64 * 1024;

let session = null;
let script = null;
let attachedPid = null;
let attaching = false;
let shuttingDown = false;
let currentConfig = normalizeConfig({});
let lastStatusKey = '';
const pendingPreparations = new Map();

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function emitLog(message) {
  emit({ type: 'log', message: String(message) });
}

function emitStatus(state, detail) {
  const normalizedDetail = String(detail || '');
  const key = `${state}\n${normalizedDetail}`;
  if (key === lastStatusKey) return;
  lastStatusKey = key;
  emit({ type: 'status', state, detail: normalizedDetail });
}

function normalizeConfig(value) {
  const source = value && typeof value === 'object' ? value : {};
  return {
    disableModuleCheck: source.disableModuleCheck !== false,
    disableForegroundCheck: source.disableForegroundCheck !== false,
    replaceVideoUrls: source.replaceVideoUrls !== false,
    scoringEnabled: source.scoringEnabled !== false,
  };
}

function sha256(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const input = fs.createReadStream(filePath);
    input.on('data', (chunk) => hash.update(chunk));
    input.on('end', () => resolve(hash.digest('hex').toLowerCase()));
    input.on('error', reject);
  });
}

async function findTarget() {
  const device = await frida.getLocalDevice();
  const processes = await device.enumerateProcesses({ scope: 'full' });
  return processes
    .filter((candidate) => candidate.name === processName)
    .sort((left, right) => left.pid - right.pid)[0] || null;
}

async function ensureAttached() {
  if (shuttingDown || attaching || session) return;
  attaching = true;
  let activeSession = null;
  let activeScript = null;
  try {
    const target = await findTarget();
    if (!target) {
      emitStatus('waiting', `${processName} の起動を待っています`);
      return;
    }
    const executablePath = target.parameters && target.parameters.path;
    if (!executablePath || !fs.existsSync(executablePath)) {
      emitStatus('unsupported', 'DAM実行ファイルのパスを確認できません');
      return;
    }
    const actualHash = await sha256(executablePath);
    if (actualHash !== supportedHash) {
      emitStatus(
        'unsupported',
        `未対応のDAMです。${targetLabel}のSHA-256と一致しません (${actualHash.slice(0, 12)}…)`,
      );
      return;
    }

    emitStatus('attaching', `${targetLabel} (PID ${target.pid}) へ接続中`);
    activeSession = await frida.attach(target.pid);
    const identityPath = path.join(helperDirectory, 'identity.js');
    const agentPath = path.join(helperDirectory, 'agent.js');
    const identityBody = fs.readFileSync(identityPath, 'utf8');
    const agentBody = fs.readFileSync(agentPath, 'utf8');
    const source = composeAgentSource({
      manifest,
      runtimeConfig,
      identitySource: identityBody,
      agentSource: agentBody,
    });
    activeScript = await activeSession.createScript(source, {
      name: 'dam-for-windows-tools-agent',
    });
    activeScript.message.connect(handleAgentMessage);
    activeSession.detached.connect((reason) => {
      if (session === activeSession) {
        session = null;
        script = null;
        attachedPid = null;
        emitStatus('waiting', `DAMから切断されました: ${reason}`);
      }
    });
    await activeScript.load();
    await activeScript.exports.initialize(currentConfig);
    session = activeSession;
    script = activeScript;
    attachedPid = target.pid;
    emitStatus('attached', `${targetLabel} 接続済み (PID ${target.pid})`);
  } catch (error) {
    emitStatus('attach-error', `DAM接続失敗: ${error.message || error}`);
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
    await detach();
  } finally {
    attaching = false;
  }
}

function handleAgentMessage(message) {
  if (message.type === 'error') {
    emitLog(`Frida agent error: ${message.description || 'unknown error'}`);
    return;
  }
  if (message.type !== 'send') return;
  const payload = message.payload;
  if (!payload || typeof payload !== 'object') return;
  switch (payload.type) {
    case 'log':
      emitLog(payload.message || '');
      break;
    case 'patch-error':
      emit({ type: 'patch-error', message: String(payload.message || '') });
      break;
    case 'metadata':
      emit({ type: 'metadata', candidates: payload.candidates || [] });
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
      emit(payload);
      break;
    case 'prepare': {
      const requestId = String(payload.requestId || '');
      if (!requestId) break;
      emit(payload);
      const timer = setTimeout(() => {
        pendingPreparations.delete(requestId);
        if (script) {
          script.post({
            type: `prepare-result:${requestId}`,
            payload: {
              accepted: false,
              localUrl: '',
              error: 'registration timeout',
            },
          });
        }
      }, 1900);
      pendingPreparations.set(requestId, timer);
      break;
    }
    default:
      emitLog(`未処理のAgentイベント: ${payload.type || 'unknown'}`);
  }
}

async function updateConfig(command) {
  currentConfig = normalizeConfig(command);
  if (script) await script.exports.updateConfig(currentConfig);
}

async function detach() {
  const activeScript = script;
  const activeSession = session;
  script = null;
  session = null;
  attachedPid = null;
  for (const timer of pendingPreparations.values()) clearTimeout(timer);
  pendingPreparations.clear();
  if (activeScript) {
    try {
      await activeScript.exports.restoreAll();
    } catch (_) {
      // The target may already be gone.
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

async function handleCommand(command) {
  switch (command.type) {
    case 'config':
      await updateConfig(command);
      break;
    case 'prepareResult':
      if (script && command.requestId) {
        const requestId = String(command.requestId);
        const timer = pendingPreparations.get(requestId);
        if (!timer) break;
        clearTimeout(timer);
        pendingPreparations.delete(requestId);
        script.post({
          type: `prepare-result:${requestId}`,
          payload: {
            accepted: command.accepted === true,
            localUrl: String(command.localUrl || ''),
            error: String(command.error || ''),
          },
        });
      }
      break;
    case 'reconnect':
      await detach();
      await ensureAttached();
      break;
    case 'remoteSearch': {
      const requestId = String(command.requestId || '');
      const query = String(command.query || '');
      if (!script) {
        emit({
          type: 'remote-search-result',
          requestId,
          query,
          total: 0,
          rows: [],
          error: 'DAMに接続されていません',
        });
        break;
      }
      try {
        await script.exports.remoteSearch(
          requestId,
          query,
          String(command.mode || 'keyword'),
        );
      } catch (error) {
        emit({
          type: 'remote-search-result',
          requestId,
          query,
          mode: String(command.mode || 'keyword'),
          total: 0,
          rows: [],
          error: String(error && error.message ? error.message : error),
        });
      }
      break;
    }
    case 'remoteDetail': {
      const requestId = String(command.requestId || '');
      if (!script) {
        emit({
          type: 'remote-detail-result',
          requestId,
          error: 'DAMに接続されていません',
        });
        break;
      }
      try {
        await script.exports.remoteDetail(
          requestId,
          String(command.token || ''),
        );
      } catch (error) {
        emit({
          type: 'remote-detail-result',
          requestId,
          error: String(error && error.message ? error.message : error),
        });
      }
      break;
    }
    case 'remoteReserve': {
      const requestId = String(command.requestId || '');
      if (!script) {
        emit({
          type: 'remote-reserve-result',
          requestId,
          accepted: false,
          message: 'DAMに接続されていません',
        });
        break;
      }
      try {
        await script.exports.remoteReserve(requestId, String(command.token || ''), {
          mode: String(command.mode || 'normal'),
          key: Number(command.key || 0),
          scoring: command.scoring === true,
          playType: String(command.playType || 'standard'),
        });
      } catch (error) {
        emit({
          type: 'remote-reserve-result',
          requestId,
          accepted: false,
          message: String(error && error.message ? error.message : error),
        });
      }
      break;
    }
    case 'remoteFavorite': {
      const requestId = String(command.requestId || '');
      if (!script) {
        emit({
          type: 'remote-favorite-result',
          requestId,
          accepted: false,
          favorite: false,
          message: 'DAMに接続されていません',
        });
        break;
      }
      try {
        await script.exports.remoteFavorite(
          requestId,
          String(command.token || ''),
          command.action === 'remove' ? 'remove' : 'add',
        );
      } catch (error) {
        emit({
          type: 'remote-favorite-result',
          requestId,
          accepted: false,
          favorite: command.action !== 'remove',
          message: String(error && error.message ? error.message : error),
        });
      }
      break;
    }
    case 'remoteState':
    case 'remoteControl':
    case 'remoteQueue':
    case 'remoteQueueAction': {
      const requestId = String(command.requestId || '');
      const resultType = {
        remoteState: 'remote-state-result',
        remoteControl: 'remote-control-result',
        remoteQueue: 'remote-queue-result',
        remoteQueueAction: 'remote-queue-action-result',
      }[command.type];
      if (!script) {
        emit({ type: resultType, requestId, error: 'DAMに接続されていません' });
        break;
      }
      try {
        let result;
        if (command.type === 'remoteState') {
          result = await script.exports.remoteState();
        } else if (command.type === 'remoteControl') {
          result = await script.exports.remoteControl(String(command.action || ''));
        } else if (command.type === 'remoteQueue') {
          result = await script.exports.remoteQueue();
        } else {
          result = await script.exports.remoteQueueAction(
            String(command.action || ''),
            String(command.token || ''),
          );
        }
        emit({ type: resultType, requestId, result });
      } catch (error) {
        emit({
          type: resultType,
          requestId,
          error: String(error && error.message ? error.message : error),
        });
      }
      break;
    }
    case 'shutdown':
      await shutdown();
      break;
    default:
      emitLog(`不明なヘルパーコマンド: ${command.type || 'unknown'}`);
  }
}

async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  await detach();
  process.exit(0);
}

const input = readline.createInterface({ input: process.stdin });
input.on('line', (line) => {
  if (line.length > maxCommandLineLength) {
    emitLog('上限を超えるJSON Linesコマンドを拒否しました');
    return;
  }
  try {
    const command = JSON.parse(line);
    Promise.resolve(handleCommand(command)).catch((error) => {
      emitLog(`コマンド処理失敗: ${error.message || error}`);
    });
  } catch (_) {
    emitLog('不正なJSON Linesコマンドを拒否しました');
  }
});
input.on('close', () => shutdown());
process.on('SIGINT', () => shutdown());
process.on('SIGTERM', () => shutdown());
process.on('uncaughtException', (error) => {
  emitLog(`ヘルパー例外: ${error.message || error}`);
});
process.on('unhandledRejection', (error) => {
  emitLog(`ヘルパー非同期例外: ${error && error.message ? error.message : error}`);
});

emitStatus('ready', 'Fridaヘルパー起動済み');
setInterval(() => {
  ensureAttached().catch((error) => emitLog(`監視失敗: ${error.message || error}`));
}, 750).unref();
await ensureAttached();
