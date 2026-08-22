// Project: DAM for Windows Tools
// File: agent_source.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

function injectableModuleSource(source) {
  return String(source).replace(
    /^(\s*)export\s+(?=(?:async\s+)?function\s|class\s|(?:const|let|var)\s)/gm,
    '$1',
  );
}

export const agentFragmentNames = Object.freeze([
  '00_runtime.js',
  '10_playback.js',
  '20_remote_playback.js',
  '30_scoring.js',
  '40_remote_requests.js',
  '50_remote_hooks.js',
  '60_validation.js',
  '70_rpc_exports.js',
]);

export function composeAgentSource({
  manifest,
  runtimeConfig,
  identitySource,
  agentSources,
}) {
  if (!Array.isArray(agentSources) || agentSources.length === 0) {
    throw new TypeError('agentSources must contain at least one fragment');
  }
  return (
    `const DAM_TARGET_MANIFEST = ${JSON.stringify(manifest)};\n` +
    `const DAM_RUNTIME_CONFIG = ${JSON.stringify(runtimeConfig)};\n` +
    `${injectableModuleSource(identitySource)}\n` +
    agentSources.map(injectableModuleSource).join('\n')
  );
}
