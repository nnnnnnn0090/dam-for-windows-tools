//! 採点オーバーレイDLLを自プロセスへ読み込み、表示を目視確認する試験用exeです。
//!
//! DAMの代わりにスプラッシュ風の小窓と主画面を作り、Frida Agentと同じ順序でDLLの公開関数を呼びます。
//!
//! ```text
//! cargo build -p scoring-overlay --example overlay_demo
//! overlay_demo.exe [アイコンのディレクトリ] [--hold] [--dll <DLLのパス>]
//! ```
//!
//! `--hold` を付けると、終了処理をせずに主画面を閉じるまで表示を続けます。

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{CreateSolidBrush, HBRUSH};
use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress, LoadLibraryW};
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::Win32::UI::WindowsAndMessaging::{
    AdjustWindowRect, CW_USEDEFAULT, CreateWindowExW, DefWindowProcW, DestroyWindow,
    DispatchMessageW, EnumWindows, GW_OWNER, GetClassNameW, GetMessageW, GetWindow,
    GetWindowThreadProcessId, IsWindowVisible, MSG, PostQuitMessage, RegisterClassExW, SW_SHOW,
    SetTimer, ShowWindow, TranslateMessage, WINDOW_EX_STYLE, WM_CLOSE, WM_TIMER, WNDCLASSEXW,
    WS_OVERLAPPEDWINDOW, WS_POPUP, WS_VISIBLE,
};
use windows::core::{BOOL, HSTRING, PCSTR, w};

/// 自プロセス内のオーバーレイウィンドウを探し、(可視か, 所有ウィンドウ)を返します。
fn overlay_state() -> Option<(bool, Option<HWND>)> {
    unsafe extern "system" fn callback(window: HWND, parameter: LPARAM) -> BOOL {
        // SAFETY: `overlay_state` が渡したローカル変数です。
        let found = unsafe { &mut *(parameter.0 as *mut Option<(bool, Option<HWND>)>) };
        let mut process_id = 0;
        let mut class = [0u16; 128];
        // SAFETY: 列挙中のウィンドウへの読み取り専用の問い合わせです。
        unsafe {
            GetWindowThreadProcessId(window, Some(&mut process_id));
            let length = GetClassNameW(window, &mut class) as usize;
            let name = String::from_utf16_lossy(&class[..length]);
            if process_id == GetCurrentProcessId()
                && name.starts_with("DAMforWindowsTools.ScoringOverlay.")
            {
                *found = Some((
                    IsWindowVisible(window).as_bool(),
                    GetWindow(window, GW_OWNER).ok(),
                ));
            }
        }
        BOOL(1)
    }
    let mut found = None;
    // SAFETY: コールバックは列挙中だけ `found` を参照します。
    let _ = unsafe { EnumWindows(Some(callback), LPARAM(&mut found as *mut _ as isize)) };
    found
}

type RawProc = unsafe extern "system" fn() -> isize;
type StartFn = unsafe extern "system" fn(*const u16) -> BOOL;
type VoidFn = unsafe extern "system" fn();
type UpdateFn = unsafe extern "system" fn(i32, i32);
type FlagFn = unsafe extern "system" fn(BOOL);

struct Api {
    start: StartFn,
    begin: VoidFn,
    update: UpdateFn,
    set_visible: FlagFn,
    set_show_zero: FlagFn,
    end: VoidFn,
    heartbeat: VoidFn,
    stop: VoidFn,
}

fn load_api(path: &Path) -> Api {
    // SAFETY: 試験用に自前ビルドしたDLLを読み込み、v1互換のシグネチャで関数を解決します。
    unsafe {
        let module = LoadLibraryW(&HSTRING::from(path.as_os_str())).expect("DLLを読み込めません");
        let resolve = |name: &[u8]| {
            GetProcAddress(module, PCSTR(name.as_ptr()))
                .unwrap_or_else(|| panic!("{} がありません", String::from_utf8_lossy(name)))
        };
        Api {
            start: std::mem::transmute::<RawProc, StartFn>(resolve(b"DamScoringOverlayStart\0")),
            begin: std::mem::transmute::<RawProc, VoidFn>(resolve(b"DamScoringOverlayBegin\0")),
            update: std::mem::transmute::<RawProc, UpdateFn>(resolve(b"DamScoringOverlayUpdate\0")),
            set_visible: std::mem::transmute::<RawProc, FlagFn>(resolve(
                b"DamScoringOverlaySetVisible\0",
            )),
            set_show_zero: std::mem::transmute::<RawProc, FlagFn>(resolve(
                b"DamScoringOverlaySetShowZero\0",
            )),
            end: std::mem::transmute::<RawProc, VoidFn>(resolve(b"DamScoringOverlayEnd\0")),
            heartbeat: std::mem::transmute::<RawProc, VoidFn>(resolve(
                b"DamScoringOverlayHeartbeat\0",
            )),
            stop: std::mem::transmute::<RawProc, VoidFn>(resolve(b"DamScoringOverlayStop\0")),
        }
    }
}

unsafe extern "system" fn window_procedure(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_CLOSE {
        // SAFETY: メインスレッドのメッセージループを終了させます。
        unsafe { PostQuitMessage(0) };
        return LRESULT(0);
    }
    // SAFETY: 未処理のメッセージを既定処理へ渡します。
    unsafe { DefWindowProcW(window, message, wparam, lparam) }
}

fn register_class() {
    // SAFETY: 静的なクラス名とプロシージャで1回だけ登録します。
    unsafe {
        let class = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(window_procedure),
            hInstance: GetModuleHandleW(None).unwrap_or_default().into(),
            lpszClassName: w!("OverlayDemoWindow"),
            hbrBackground: HBRUSH(CreateSolidBrush(COLORREF(0x0040_2818)).0),
            ..Default::default()
        };
        RegisterClassExW(&class);
    }
}

/// DAMの主画面を模した、クライアント領域が1280x720の通常ウィンドウを作ります。
fn create_main(title: &str) -> HWND {
    let mut rect = RECT {
        left: 0,
        top: 0,
        right: 1280,
        bottom: 720,
    };
    // SAFETY: 登録済みクラスから通常ウィンドウを作ります。
    unsafe {
        let _ = AdjustWindowRect(&mut rect, WS_OVERLAPPEDWINDOW, false);
        let window = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("OverlayDemoWindow"),
            &HSTRING::from(title),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            rect.right - rect.left,
            rect.bottom - rect.top,
            None,
            None,
            None,
            None,
        )
        .expect("主画面を作れません");
        let _ = ShowWindow(window, SW_SHOW);
        window
    }
}

/// 起動直後のスプラッシュを模した小さなポップアップです。
fn create_splash() -> HWND {
    // SAFETY: 登録済みクラスからポップアップを作ります。
    unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("OverlayDemoWindow"),
            w!("splash"),
            WS_POPUP | WS_VISIBLE,
            200,
            200,
            400,
            240,
            None,
            None,
            None,
            None,
        )
        .expect("スプラッシュを作れません")
    }
}

fn main() {
    let mut arguments = std::env::args().skip(1);
    let mut assets =
        PathBuf::from(r"D:\DAIICHIKOSHO Karaoke@DAM\dam-for-windows-tools\assets\scoring");
    let mut hold = false;
    let exe = std::env::current_exe().expect("exeのパスを取得できません");
    let mut dll = exe
        .parent()
        .and_then(|p| p.parent())
        .map(|p| p.join("scoring_overlay.dll"))
        .unwrap_or_default();
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--hold" => hold = true,
            "--dll" => dll = PathBuf::from(arguments.next().expect("--dll の値がありません")),
            _ => assets = PathBuf::from(argument),
        }
    }
    println!("DLL: {}", dll.display());
    println!("アイコン: {}", assets.display());
    let api = load_api(&dll);
    register_class();

    let mut splash = Some(create_splash());
    let assets_wide: Vec<u16> = assets.as_os_str().encode_wide_nul();
    // SAFETY: NUL終端したUTF-16文字列を渡します。
    let started = unsafe { (api.start)(assets_wide.as_ptr()) };
    println!("[0.0s] Start = {} (主画面はまだありません)", started.0);

    let mut main_window: Option<HWND> = None;
    let begun = Instant::now();
    let mut last_heartbeat = Instant::now();
    let mut last_update = Instant::now();
    let mut seed: u32 = 12345;
    let mut step = 0;
    // (確認時刻, 期待する可視状態, 主画面が所有者であるべきか)
    let mut checkpoints: Vec<(f32, bool, bool)> = if hold {
        Vec::new()
    } else {
        vec![
            (1.0, false, false),
            (2.2, false, true),
            (5.0, true, true),
            (11.0, true, true),
            (12.2, false, true),
            (13.6, true, true),
            (17.0, true, true),
            (21.0, true, true),
            (23.6, false, true),
            (25.2, true, true),
            (26.6, false, true),
        ]
    };
    checkpoints.reverse();
    let mut failures = 0;
    // SAFETY: スレッドタイマーで、WM_TIMERはこのスレッドのキューへ届きます。
    unsafe { SetTimer(None, 0, 50, None) };

    let mut message = MSG::default();
    // SAFETY: メインスレッドのメッセージループです。
    while unsafe { GetMessageW(&mut message, None, 0, 0) }.0 > 0 {
        if message.hwnd.is_invalid() && message.message == WM_TIMER {
            let elapsed = begun.elapsed().as_secs_f32();
            let heartbeat_paused = !hold && (8.0..13.0).contains(&elapsed);
            if let Some(&(at, expect_visible, expect_main_owner)) = checkpoints.last()
                && elapsed >= at
            {
                checkpoints.pop();
                let state = overlay_state();
                let visible = state.is_some_and(|(visible, _)| visible);
                let owner_ok =
                    !expect_main_owner || state.and_then(|(_, owner)| owner) == main_window;
                let ok = visible == expect_visible && owner_ok;
                failures += usize::from(!ok);
                println!(
                    "[{elapsed:.1}s] 確認: 可視={visible} (期待 {expect_visible}) 所有者が主画面={owner_ok} → {}",
                    if ok { "OK" } else { "NG" }
                );
            }
            // SAFETY: 読み込み済みDLLの関数呼び出しです。
            unsafe {
                if !heartbeat_paused && last_heartbeat.elapsed() >= Duration::from_secs(1) {
                    (api.heartbeat)();
                    last_heartbeat = Instant::now();
                }
                if (2..7).contains(&step)
                    && !heartbeat_paused
                    && last_update.elapsed() >= Duration::from_millis(400)
                {
                    seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12345);
                    let id = ((seed >> 16) % 44) as i32;
                    (api.update)(id, 1);
                    last_update = Instant::now();
                }
                let log = |text: &str| println!("[{elapsed:.1}s] {text}");
                match step {
                    0 if elapsed >= 1.5 => {
                        main_window = Some(create_main("DAM overlay demo #1"));
                        if let Some(window) = splash.take() {
                            let _ = DestroyWindow(window);
                        }
                        log("主画面を作成しスプラッシュを破棄 → 主画面へ追従するはず");
                        step = 1;
                    }
                    1 if elapsed >= 2.5 => {
                        (api.begin)();
                        (api.set_show_zero)(BOOL(1));
                        (api.set_visible)(BOOL(1));
                        log("Begin/SetShowZero(1)/SetVisible(1) → 36タイル表示");
                        step = 2;
                    }
                    2 if hold => {}
                    2 if elapsed >= 8.0 => {
                        log("ハートビート停止 → 約3.5秒後(11.5s付近)に消えるはず");
                        step = 3;
                    }
                    3 if elapsed >= 13.0 => {
                        log("ハートビート再開 → 再表示されるはず");
                        step = 4;
                    }
                    4 if elapsed >= 16.0 => {
                        if let Some(window) = main_window.take() {
                            let _ = DestroyWindow(window);
                        }
                        main_window = Some(create_main("DAM overlay demo #2 (再生成)"));
                        log("主画面を破棄して再生成 → 新しい主画面へ追従するはず");
                        step = 5;
                    }
                    5 if elapsed >= 20.0 => {
                        (api.set_show_zero)(BOOL(0));
                        log("SetShowZero(0) → 検出済みだけを詰めて表示");
                        step = 6;
                    }
                    6 if elapsed >= 23.0 => {
                        (api.set_visible)(BOOL(0));
                        log("SetVisible(0) → 非表示");
                        step = 7;
                    }
                    7 if elapsed >= 24.5 => {
                        (api.set_visible)(BOOL(1));
                        log("SetVisible(1) → 回数を保ったまま再表示");
                        step = 8;
                    }
                    8 if elapsed >= 26.0 => {
                        (api.end)();
                        log("End → 非表示");
                        step = 9;
                    }
                    9 if elapsed >= 27.0 => {
                        let stopped = Instant::now();
                        (api.stop)();
                        let gone = overlay_state().is_none();
                        failures += usize::from(!gone);
                        log(&format!(
                            "Stop 完了 ({} ms) オーバーレイ破棄済み={gone} → {}",
                            stopped.elapsed().as_millis(),
                            if gone { "OK" } else { "NG" }
                        ));
                        PostQuitMessage(0);
                        step = 10;
                    }
                    _ => {}
                }
            }
            continue;
        }
        // SAFETY: 通常のメッセージ配送です。
        unsafe {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    if step < 10 {
        // SAFETY: 読み込み済みDLLの関数呼び出しです。
        unsafe { (api.stop)() };
    }
    if !hold {
        println!("確認NG: {failures} 件");
        std::process::exit(i32::from(failures != 0));
    }
}

trait EncodeWideNul {
    fn encode_wide_nul(&self) -> Vec<u16>;
}

impl EncodeWideNul for std::ffi::OsStr {
    fn encode_wide_nul(&self) -> Vec<u16> {
        use std::os::windows::ffi::OsStrExt;
        self.encode_wide().chain(std::iter::once(0)).collect()
    }
}
