// Project: DAM for Windows Tools
// File: target_config.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import fs from 'node:fs';
import path from 'node:path';

export const targetManifestFilename = 'supported-dam.json';

export function loadTargetConfiguration(helperDirectory) {
  const manifestPath = path.join(helperDirectory, targetManifestFilename);
  if (!fs.existsSync(manifestPath)) {
    throw new Error(`${targetManifestFilename} is missing`);
  }

  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const target = manifest && manifest.target;
  const processName = String(target && target.processName || '').trim();
  const fileVersion = String(target && target.fileVersion || '').trim();
  const supportedHash = String(target && target.sha256 || '').toLowerCase();
  if (!processName || !fileVersion || !/^[0-9a-f]{64}$/.test(supportedHash)) {
    throw new Error(`${targetManifestFilename} has an invalid target definition`);
  }

  const mediaOrigin = normalizeMediaOrigin(process.env.DAM_TOOLS_MEDIA_ORIGIN);
  return Object.freeze({
    manifest,
    processName,
    supportedHash,
    targetLabel: `DAM for Windows ${fileVersion}`,
    runtimeConfig: Object.freeze({ mediaOrigin }),
  });
}

export function normalizeMediaOrigin(value) {
  const url = new URL(String(value || ''));
  if (
    url.protocol !== 'http:' ||
    url.hostname !== '127.0.0.1' ||
    url.username ||
    url.password ||
    url.pathname !== '/' ||
    url.search ||
    url.hash
  ) {
    throw new Error('DAM_TOOLS_MEDIA_ORIGIN must be a loopback HTTP origin');
  }
  return url.origin;
}
