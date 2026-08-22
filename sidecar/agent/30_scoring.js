// Project: DAM for Windows Tools
// File: agent/30_scoring.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

function beginScoringSession() {
  if (!config.scoringEnabled || scoringSessionActive) return;
  scoringSessionActive = true;
  lastOrnamentTimestamp = -1;
  send({ type: 'scoring-start' });
}

function finishScoringSession() {
  if (scoringSessionActive) send({ type: 'scoring-stop' });
  scoringSessionActive = false;
  lastOrnamentTimestamp = -1;
}

function installScoringHooks() {
  const start = DAM_TARGET_MANIFEST.hooks.scoringStart;
  const stop = DAM_TARGET_MANIFEST.hooks.scoringStop;
  const ornament = DAM_TARGET_MANIFEST.hooks.realtimeVocalOrnament;

  Interceptor.attach(rva(start.rva), {
    onLeave(result) {
      if (result.toInt32() !== 0) beginScoringSession();
    },
  });

  Interceptor.attach(rva(stop.rva), {
    onLeave(result) {
      if (result.toInt32() !== 0) finishScoringSession();
    },
  });

  Interceptor.attach(rva(ornament.rva), {
    onEnter(args) {
      this.output = args[parseInteger(ornament.outputArgument)];
    },
    onLeave(result) {
      if (!config.scoringEnabled || result.toInt32() === 0) return;
      const output = this.output;
      if (!output || output.isNull()) return;
      try {
        const timestamp = output.add(parseInteger(ornament.timestampOffset)).readS32();
        if (timestamp <= lastOrnamentTimestamp) return;
        beginScoringSession();
        lastOrnamentTimestamp = timestamp;
        const count = parseInteger(ornament.techniqueCount);
        const stride = parseInteger(ornament.valueStride);
        for (let technique = 0; technique < count; technique += 1) {
          const value = output.add(technique * stride).readS32();
          if (value > 0) {
            send({
              type: 'scoring-technique',
              technique,
              value,
              timestamp,
            });
          }
        }
      } catch (_) {
        // Scoring display is observational; never affect DAM playback.
      }
    },
  });
}
