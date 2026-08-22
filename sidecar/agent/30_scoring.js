// Project: DAM for Windows Tools
// File: agent/30_scoring.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

/** 採点表示が有効なときだけ、新しい1曲分の監視セッションを開始します。 */
function beginScoringSession() {
  if (!config.scoringEnabled || scoringSessionActive) return;
  scoringSessionActive = true;
  lastOrnamentTimestamp = -1;
  send({ type: 'scoring-start' });
}

/** 採点終了を通知し、次曲の重複判定状態を初期化します。 */
function finishScoringSession() {
  if (scoringSessionActive) send({ type: 'scoring-stop' });
  scoringSessionActive = false;
  lastOrnamentTimestamp = -1;
}

/** 採点開始・終了・リアルタイム歌唱技法を読み取り専用で監視します。 */
function installScoringHooks() {
  const start = DAM_TARGET_MANIFEST.hooks.scoringStart;
  const stop = DAM_TARGET_MANIFEST.hooks.scoringStop;
  const ornament = DAM_TARGET_MANIFEST.hooks.realtimeVocalOrnament;

  Interceptor.attach(rva(start.rva), {
    // DAMが採点開始に成功した呼び出しだけをセッション開始として扱います。
    onLeave(result) {
      if (result.toInt32() !== 0) beginScoringSession();
    },
  });

  Interceptor.attach(rva(stop.rva), {
    // DAMが採点終了に成功した呼び出しだけをセッション終了として扱います。
    onLeave(result) {
      if (result.toInt32() !== 0) finishScoringSession();
    },
  });

  Interceptor.attach(rva(ornament.rva), {
    // 呼び出し終了後も参照できるよう、技法出力ポインターだけを保存します。
    onEnter(args) {
      this.output = args[parseInteger(ornament.outputArgument)];
    },
    // 新しい時刻の技法値だけを読み取り、正の検出結果をFlutterへ通知します。
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
        // 採点表示は観測専用なので、読み取り失敗をDAMの再生へ波及させません。
      }
    },
  });
}
