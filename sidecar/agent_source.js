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

export function composeAgentSource({
  manifest,
  runtimeConfig,
  identitySource,
  agentSource,
}) {
  return (
    `const DAM_TARGET_MANIFEST = ${JSON.stringify(manifest)};\n` +
    `const DAM_RUNTIME_CONFIG = ${JSON.stringify(runtimeConfig)};\n` +
    `${injectableModuleSource(identitySource)}\n${injectableModuleSource(agentSource)}`
  );
}
