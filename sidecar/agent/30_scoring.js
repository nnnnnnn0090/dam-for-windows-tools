// Project: DAM for Windows Tools
// File: agent/30_scoring.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

/** 新しい1曲分の採点監視を開始し、表示設定に応じてDAM内グリッドを準備します。 */
function beginScoringSession() {
  if (scoringSessionActive) return;
  scoringSessionActive = true;
  lastOrnamentTimestamp = -1;
  beginDamScoringOverlay();
  send({ type: 'scoring-start' });
}

/** 採点終了を通知し、次曲の重複判定状態を初期化します。 */
function finishScoringSession() {
  if (scoringSessionActive) send({ type: 'scoring-stop' });
  endDamScoringOverlay();
  scoringSessionActive = false;
  scoringPauseActive = false;
  lastOrnamentTimestamp = -1;
}

/** 本体の歌唱表現表示とリアルタイム歌唱技法を読み取り専用で監視します。 */
function installScoringHooks() {
  const displayStart = DAM_TARGET_MANIFEST.hooks.scoringDisplayStart;
  const displayStop = DAM_TARGET_MANIFEST.hooks.scoringDisplayStop;
  const engineStop = DAM_TARGET_MANIFEST.hooks.scoringStop;
  const playback = DAM_TARGET_MANIFEST.hooks.remotePlaybackControl;
  const ornament = DAM_TARGET_MANIFEST.hooks.realtimeVocalOrnament;

  Interceptor.attach(rva(displayStart.rva), {
    // 本体が歌唱表現パネルを有効化する命令と同じ瞬間に追加表示を開始します。
    onEnter() {
      beginScoringSession();
    },
  });

  Interceptor.attach(rva(displayStop.rva), {
    // 本体が歌唱表現パネルを無効化する命令と同じ瞬間に追加表示を消します。
    onEnter() {
      finishScoringSession();
    },
  });

  Interceptor.attach(rva(playback.pauseRva), {
    // 停止関数が内部で先に呼ばれても一時停止と判別できるよう、要求状態を先に保持します。
    onEnter(args) {
      this.requestedPause = args[0].toInt32() !== 0;
      scoringPauseActive = this.requestedPause;
      if (this.requestedPause) {
        hideDamScoringOverlay();
      }
    },
    // 実際の一時停止フラグを読み直し、拒否された操作や多重要求でも表示を同期します。
    onLeave() {
      let paused = this.requestedPause;
      try {
        paused = rva(playback.pausedRva).readU8() !== 0;
      } catch (_) {
        // 状態を読めない場合は、入口で取得した要求値を安全な代替値にします。
      }
      scoringPauseActive = paused;
      if (paused) hideDamScoringOverlay();
      else if (scoringSessionActive) showDamScoringOverlay();
    },
  });

  Interceptor.attach(rva(playback.stopRva), {
    // 本体・リモコンの演奏停止要求を受けた時点で、結果処理を待たず表示を閉じます。
    onEnter() {
      finishScoringSession();
    },
  });

  Interceptor.attach(rva(engineStop.rva), {
    // 別経路の停止も即時反映し、一時停止だけはセッション回数を維持します。
    onEnter() {
      let paused = scoringPauseActive;
      try {
        paused = paused || rva(playback.pausedRva).readU8() !== 0;
      } catch (_) {
        // 状態を読めない場合も、表示を残さない側へ倒します。
      }
      if (paused) hideDamScoringOverlay();
      else finishScoringSession();
    },
  });

  Interceptor.attach(rva(ornament.rva), {
    // 呼び出し終了後も参照できるよう、技法出力ポインターだけを保存します。
    onEnter(args) {
      this.output = args[parseInteger(ornament.outputArgument)];
    },
    // 新しい時刻の技法値だけを読み取り、正の検出結果をFlutterへ通知します。
    onLeave(result) {
      if (result.toInt32() === 0) return;
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
            updateDamScoringOverlay(technique, value);
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
