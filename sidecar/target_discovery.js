// Project: DAM for Windows Tools
// File: target_discovery.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import crypto from 'node:crypto';
import fs from 'node:fs';

import * as frida from 'frida';

/** 実行ファイルをストリームで読み、比較用の小文字SHA-256を計算します。 */
export function sha256(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const input = fs.createReadStream(filePath);
    input.on('data', (chunk) => hash.update(chunk));
    input.on('end', () => resolve(hash.digest('hex').toLowerCase()));
    input.on('error', reject);
  });
}

/** ローカルプロセスから対象名を完全一致で探し、最も早いPIDの1件を返します。 */
export async function findTarget(processName) {
  const device = await frida.getLocalDevice();
  const processes = await device.enumerateProcesses({ scope: 'full' });
  return processes
    .filter((candidate) => candidate.name === processName)
    .sort((left, right) => left.pid - right.pid)[0] || null;
}
