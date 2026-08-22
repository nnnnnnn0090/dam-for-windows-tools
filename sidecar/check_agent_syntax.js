// Project: DAM for Windows Tools
// File: check_agent_syntax.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import fs from 'node:fs';

import { agentFragmentNames, composeAgentSource } from './agent_source.js';

const agentSources = agentFragmentNames.map((filename) =>
  fs.readFileSync(new URL(`./agent/${filename}`, import.meta.url), 'utf8'),
);
const source = composeAgentSource({
  manifest: { target: { processName: 'DKKaraokeWindows.exe' } },
  runtimeConfig: { mediaOrigin: 'http://127.0.0.1:8765' },
  identitySource: fs.readFileSync(new URL('./identity.js', import.meta.url), 'utf8'),
  agentSources,
});

new Function(source);
