//! DAMの採点画面へ歌唱技法グリッドを重ねる描画DLLです。
//!
//! Frida AgentがDAMプロセス内で `Module.load` し、下記の `DamScoringOverlay*` を呼び出します。
//! 公開関数のシグネチャはv1のC++版と完全互換です。

mod model;
mod overlay;
mod render;

use std::ffi::OsString;
use std::os::windows::ffi::OsStringExt;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

use windows::core::BOOL;

pub use model::{TECHNIQUE_COUNT, TECHNIQUES, canonical_technique_id, technique_index};
use overlay::Overlay;

/// パス文字列として受け付ける最大のUTF-16長です。
const MAX_PATH_UNITS: usize = 32_768;

static OVERLAY: Mutex<Option<Overlay>> = Mutex::new(None);

fn lock() -> MutexGuard<'static, Option<Overlay>> {
    OVERLAY
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn with_overlay(callback: impl FnOnce(&Overlay)) {
    if let Some(overlay) = lock().as_ref() {
        callback(overlay);
    }
}

/// NUL終端UTF-16文字列を読み取ります。nullや空文字列、長すぎる値は `None` です。
///
/// # Safety
/// `text` はnullか、NUL終端された読み取り可能なUTF-16文字列を指す必要があります。
unsafe fn read_wide(text: *const u16) -> Option<PathBuf> {
    if text.is_null() {
        return None;
    }
    let mut length = 0;
    // SAFETY: 呼び出し元の保証により、NUL終端までは読み取り可能です。
    while unsafe { *text.add(length) } != 0 {
        length += 1;
        if length >= MAX_PATH_UNITS {
            return None;
        }
    }
    if length == 0 {
        return None;
    }
    // SAFETY: 直前に長さを確認した範囲だけを参照します。
    let units = unsafe { std::slice::from_raw_parts(text, length) };
    Some(PathBuf::from(OsString::from_wide(units)))
}

/// 描画スレッドを開始し、歌唱技法アイコンを指定ディレクトリから読み込みます。
///
/// DAMのウィンドウがまだ無い場合も成功し、出現後に追従します。起動済みならハートビートだけ更新します。
///
/// # Safety
/// `asset_directory` はnullか、NUL終端されたUTF-16文字列を指す必要があります。
#[unsafe(no_mangle)]
pub unsafe extern "system" fn DamScoringOverlayStart(asset_directory: *const u16) -> BOOL {
    // SAFETY: 呼び出し元の保証をそのまま引き継ぎます。
    let Some(asset_directory) = (unsafe { read_wide(asset_directory) }) else {
        return BOOL(0);
    };
    let mut guard = lock();
    if let Some(current) = guard.as_ref() {
        if current.is_alive() {
            current.heartbeat();
            return BOOL(1);
        }
        // 描画スレッドが異常終了していた場合は作り直します。
        if let Some(dead) = guard.take() {
            dead.stop();
        }
    }
    match Overlay::start(asset_directory) {
        Some(overlay) => {
            *guard = Some(overlay);
            BOOL(1)
        }
        None => BOOL(0),
    }
}

/// 1曲分のカウンターを初期化してセッションを開始します。表示状態は変えません。
#[unsafe(no_mangle)]
pub extern "system" fn DamScoringOverlayBegin() {
    with_overlay(Overlay::begin);
}

/// DAM採点エンジンの技法IDと今回増えた回数を表示へ反映します。
#[unsafe(no_mangle)]
pub extern "system" fn DamScoringOverlayUpdate(technique_id: i32, value: i32) {
    with_overlay(|overlay| overlay.update(technique_id, value));
}

/// 現在曲の回数を保ったまま、追加グリッドの表示要求だけを切り替えます。
#[unsafe(no_mangle)]
pub extern "system" fn DamScoringOverlaySetVisible(visible: BOOL) {
    with_overlay(|overlay| overlay.set_visible(visible.as_bool()));
}

/// 0回の技法を含む全種類表示と、検出済みだけの表示を切り替えます。
#[unsafe(no_mangle)]
pub extern "system" fn DamScoringOverlaySetShowZero(show_zero: BOOL) {
    with_overlay(|overlay| overlay.set_show_zero(show_zero.as_bool()));
}

/// 現在曲の表示を閉じ、次の採点開始まで待機します。
#[unsafe(no_mangle)]
pub extern "system" fn DamScoringOverlayEnd() {
    with_overlay(Overlay::end);
}

/// Frida Agentが生存していることを描画スレッドへ通知します。
#[unsafe(no_mangle)]
pub extern "system" fn DamScoringOverlayHeartbeat() {
    with_overlay(Overlay::heartbeat);
}

/// グローバル参照を先に外して追加更新を遮断し、描画スレッドを終了させます。
#[unsafe(no_mangle)]
pub extern "system" fn DamScoringOverlayStop() {
    let overlay = lock().take();
    if let Some(overlay) = overlay {
        overlay.stop();
    }
}
