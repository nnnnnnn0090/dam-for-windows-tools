// Project: DAM for Windows Tools
// File: agent_source.test.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

import { agentFragmentNames, composeAgentSource } from '../agent_source.js';

test('composes a classic Frida script without ES module exports', () => {
  const fragmentDirectory = new URL('../agent/', import.meta.url);
  const actualFragmentNames = fs
    .readdirSync(fragmentDirectory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.js'))
    .map((entry) => entry.name)
    .sort();
  assert.deepEqual(actualFragmentNames, [...agentFragmentNames].sort());

  const identitySource = fs.readFileSync(
    new URL('../identity.js', import.meta.url),
    'utf8',
  );
  const agentSources = agentFragmentNames.map((filename) =>
    fs.readFileSync(new URL(`../agent/${filename}`, import.meta.url), 'utf8'),
  );
  const source = composeAgentSource({
    manifest: { target: { processName: 'DKKaraokeWindows.exe' } },
    runtimeConfig: { mediaOrigin: 'http://127.0.0.1:8765' },
    identitySource,
    agentSources,
  });

  assert.doesNotMatch(source, /^(?:\s*)export\s/m);
  assert.doesNotThrow(() => new Function(source));
  assert.match(source, /function extractVideoAssetId\(value\)/);
});

test('DAM play history uses its verified catalog and list-detail path', () => {
  const manifest = JSON.parse(fs.readFileSync(
    new URL('../supported-dam.json', import.meta.url),
    'utf8',
  ));
  const history = manifest.hooks.remoteCatalog.history;

  assert.deepEqual({
    entryRva: history.entryRva,
    resultRva: history.resultRva,
    copyListRva: history.copyListRva,
    errorRva: history.errorRva,
    recordStride: history.recordStride,
    artistOffset: history.artistOffset,
    titleOffset: history.titleOffset,
    listMode: history.listMode,
    remoteOnlyPreludePatches: history.remoteOnlyPreludePatches,
  }, {
    entryRva: '0x0fb160',
    resultRva: '0x0fb4b0',
    copyListRva: '0x0f9770',
    errorRva: '0x105970',
    recordStride: '0x690',
    artistOffset: '0x4',
    titleOffset: '0x310',
    listMode: 2,
    remoteOnlyPreludePatches: [
      {
        rva: '0x0fb1a3',
        expectedBytes: 'e830301600',
        replacementBytes: '9090909090',
      },
      {
        rva: '0x0fb1af',
        expectedBytes: 'e810371600',
        replacementBytes: '9090909090',
      },
    ],
  });
});
