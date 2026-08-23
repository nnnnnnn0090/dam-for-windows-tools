// Project: DAM for Windows Tools
// File: agent/35_scoring_overlay.js
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

/** DLLの公開関数を固定シグネチャで解決し、採点表示をDAMプロセス内へ準備します。 */
function installDamScoringOverlay() {
  const descriptor = DAM_RUNTIME_CONFIG.scoringOverlay;
  if (!descriptor || !descriptor.libraryPath || !descriptor.assetDirectory) {
    emitLog('DAM内歌唱技法表示は描画モジュールまたはアイコンがないため無効です');
    return;
  }
  try {
    const module = Module.load(String(descriptor.libraryPath));
    const start = new NativeFunction(
      module.getExportByName('DamScoringOverlayStart'),
      'int',
      ['pointer'],
    );
    const api = {
      begin: new NativeFunction(
        module.getExportByName('DamScoringOverlayBegin'),
        'void',
        [],
      ),
      update: new NativeFunction(
        module.getExportByName('DamScoringOverlayUpdate'),
        'void',
        ['int', 'int'],
      ),
      setVisible: new NativeFunction(
        module.getExportByName('DamScoringOverlaySetVisible'),
        'void',
        ['int'],
      ),
      setShowZero: new NativeFunction(
        module.getExportByName('DamScoringOverlaySetShowZero'),
        'void',
        ['int'],
      ),
      end: new NativeFunction(
        module.getExportByName('DamScoringOverlayEnd'),
        'void',
        [],
      ),
      heartbeat: new NativeFunction(
        module.getExportByName('DamScoringOverlayHeartbeat'),
        'void',
        [],
      ),
      stop: new NativeFunction(
        module.getExportByName('DamScoringOverlayStop'),
        'void',
        [],
      ),
    };
    const assetDirectory = Memory.allocUtf16String(
      String(descriptor.assetDirectory),
    );
    if (start(assetDirectory) === 0) {
      throw new Error('描画ウィンドウを開始できませんでした');
    }
    scoringOverlayApi = api;
    scoringOverlayHeartbeatTimer = setInterval(() => {
      if (scoringOverlayApi !== null) {
        try {
          scoringOverlayApi.heartbeat();
        } catch (_) {
          // DAM終了と同時の通知失敗は、プロセス終了処理へ任せます。
        }
      }
    }, 1000);
    emitLog('DAM内歌唱技法グリッドを有効化しました');
  } catch (error) {
    scoringOverlayApi = null;
    emitLog(`DAM内歌唱技法表示を開始できません: ${error.message || error}`);
  }
}

/** 1曲分の表示値を初期化し、採点開始に合わせてグリッドを表示します。 */
function beginDamScoringOverlay() {
  if (scoringOverlayApi === null) return;
  try {
    scoringOverlayApi.begin();
    scoringOverlayApi.setShowZero(config.scoringShowZeroTechniques ? 1 : 0);
    scoringOverlayApi.setVisible(config.scoringOverlayEnabled ? 1 : 0);
  } catch (_) {
    // 表示失敗を採点エンジンと再生へ波及させません。
  }
}

/** 正の技法検知だけをネイティブ描画モジュールへ渡します。 */
function updateDamScoringOverlay(technique, value) {
  if (scoringOverlayApi === null || value <= 0) return;
  try {
    scoringOverlayApi.update(technique, value);
  } catch (_) {
    // 表示失敗を採点エンジンと再生へ波及させません。
  }
}

/** 一時停止や設定OFFで、現在回数を破棄せず追加グリッドだけを隠します。 */
function hideDamScoringOverlay() {
  if (scoringOverlayApi === null) return;
  try {
    scoringOverlayApi.setVisible(0);
  } catch (_) {
    // 表示状態の更新失敗をDAMの停止処理へ波及させません。
  }
}

/** 再開時に、同じ採点セッションの回数を保持したまま追加グリッドを戻します。 */
function showDamScoringOverlay() {
  if (scoringOverlayApi === null || !config.scoringOverlayEnabled) return;
  try {
    scoringOverlayApi.setVisible(1);
  } catch (_) {
    // 表示状態の更新失敗をDAMの再開処理へ波及させません。
  }
}

/** 0回の技法を描画する設定を、現在表示中のグリッドへ即時反映します。 */
function setDamScoringOverlayShowZero(showZero) {
  if (scoringOverlayApi === null) return;
  try {
    scoringOverlayApi.setShowZero(showZero ? 1 : 0);
  } catch (_) {
    // 配置の更新失敗時も採点イベントの収集は継続します。
  }
}

/** 採点終了または設定OFFに合わせ、現在のグリッドを閉じます。 */
function endDamScoringOverlay() {
  if (scoringOverlayApi === null) return;
  try {
    scoringOverlayApi.end();
  } catch (_) {
    // DAM終了中は描画モジュールが先に無効化される場合があります。
  }
}

/** Agent切断前にタイマーと描画スレッドを止め、DAM画面へ表示を残しません。 */
function uninstallDamScoringOverlay() {
  if (scoringOverlayHeartbeatTimer !== null) {
    clearInterval(scoringOverlayHeartbeatTimer);
    scoringOverlayHeartbeatTimer = null;
  }
  if (scoringOverlayApi === null) return;
  const api = scoringOverlayApi;
  scoringOverlayApi = null;
  try {
    api.stop();
  } catch (_) {
    // DAM終了後は解放先プロセスも終了するため、残りの復元を続けます。
  }
}
