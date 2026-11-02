//! 描画スレッドとDAMウィンドウへの追従を担当します。
//!
//! 採点フック側は原子変数を更新してスレッドへ通知するだけで、ウィンドウ操作と描画は
//! すべて専用スレッドへ閉じ込めます。共有状態は `Arc` で保持するため、停止待ちが
//! 打ち切られてもスレッドが生きている間は解放されません。

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{HINSTANCE, HMODULE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::ClientToScreen;
use windows::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx, CoUninitialize};
use windows::Win32::System::LibraryLoader::{
    GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
    GetModuleHandleExW,
};
use windows::Win32::System::SystemInformation::GetTickCount64;
use windows::Win32::System::Threading::{GetCurrentProcessId, GetCurrentThreadId};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, EnumWindows, GW_OWNER,
    GetClientRect, GetMessageW, GetWindow, GetWindowRect, GetWindowThreadProcessId, HTTRANSPARENT,
    IsIconic, IsWindow, IsWindowVisible, KillTimer, MA_NOACTIVATE, MSG, PM_NOREMOVE, PeekMessageW,
    PostThreadMessageW, RegisterClassExW, SW_HIDE, SW_SHOWNOACTIVATE, SetTimer, ShowWindow,
    TranslateMessage, UnregisterClassW, WM_APP, WM_MOUSEACTIVATE, WM_NCHITTEST, WM_QUIT, WM_TIMER,
    WM_USER, WNDCLASSEXW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TRANSPARENT,
    WS_POPUP,
};
use windows::core::{BOOL, HSTRING, PCWSTR, w};

use crate::model::{self, TECHNIQUE_COUNT};
use crate::render::{Frame, Renderer};

const REFRESH_MESSAGE: u32 = WM_APP + 0x4D1;
const FOLLOW_INTERVAL_MS: u32 = 100;
/// 所有ウィンドウより大きい候補が現れていないかを確かめる間隔(タイマー回数)です。
const OWNER_RECHECK_TICKS: u32 = 10;
const READY_TIMEOUT: Duration = Duration::from_secs(3);
const STOP_TIMEOUT: Duration = Duration::from_secs(5);

fn now_ms() -> u64 {
    // SAFETY: 引数を取らない単純な時刻取得です。
    unsafe { GetTickCount64() }
}

/// 採点フックと描画スレッドが共有する状態です。すべて原子変数で更新します。
struct Shared {
    counts: [AtomicI32; TECHNIQUE_COUNT],
    session_active: AtomicBool,
    requested_visible: AtomicBool,
    show_zero: AtomicBool,
    dirty: AtomicBool,
    stopping: AtomicBool,
    refresh_pending: AtomicBool,
    /// `model::pack_highlight` で詰めた最新タイルと強調終了時刻です。
    highlight: AtomicU64,
    last_heartbeat: AtomicU64,
    thread_id: AtomicU32,
}

impl Shared {
    fn new() -> Self {
        Self {
            counts: std::array::from_fn(|_| AtomicI32::new(0)),
            session_active: AtomicBool::new(false),
            requested_visible: AtomicBool::new(false),
            show_zero: AtomicBool::new(true),
            dirty: AtomicBool::new(true),
            stopping: AtomicBool::new(false),
            refresh_pending: AtomicBool::new(false),
            highlight: AtomicU64::new(0),
            last_heartbeat: AtomicU64::new(now_ms()),
            thread_id: AtomicU32::new(0),
        }
    }

    fn heartbeat(&self) {
        self.last_heartbeat.store(now_ms(), Ordering::Release);
    }

    /// 描画スレッドへ更新を1件だけ予約します。未処理の予約があれば重ねて送りません。
    fn request_refresh(&self) {
        self.dirty.store(true, Ordering::Release);
        if self.refresh_pending.swap(true, Ordering::AcqRel) {
            return;
        }
        let thread_id = self.thread_id.load(Ordering::Acquire);
        // SAFETY: スレッドIDへの非同期投函で、失敗しても次のタイマー周期で反映されます。
        let posted = thread_id != 0
            && unsafe { PostThreadMessageW(thread_id, REFRESH_MESSAGE, WPARAM(0), LPARAM(0)) }
                .is_ok();
        if !posted {
            self.refresh_pending.store(false, Ordering::Release);
        }
    }

    fn snapshot_counts(&self) -> [i32; TECHNIQUE_COUNT] {
        std::array::from_fn(|index| self.counts[index].load(Ordering::Acquire))
    }
}

/// 起動中の描画スレッドへの参照です。
pub struct Overlay {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

impl Overlay {
    /// 描画スレッドを開始し、メッセージキューと描画資源の準備完了まで待ちます。
    ///
    /// DAMのウィンドウがまだ無くても成功し、出現後に追従します。
    pub fn start(asset_directory: PathBuf) -> Option<Self> {
        let shared = Arc::new(Shared::new());
        let (ready_tx, ready_rx) = mpsc::channel();
        let thread_shared = Arc::clone(&shared);
        let thread = std::thread::Builder::new()
            .name("dam-scoring-overlay".into())
            .spawn(move || thread_main(thread_shared, asset_directory, ready_tx))
            .ok()?;
        let overlay = Self {
            shared,
            thread: Some(thread),
        };
        if ready_rx.recv_timeout(READY_TIMEOUT) == Ok(true) {
            Some(overlay)
        } else {
            overlay.stop();
            None
        }
    }

    /// 描画スレッドが動作中かを返します。
    pub fn is_alive(&self) -> bool {
        self.thread
            .as_ref()
            .is_some_and(|thread| !thread.is_finished())
    }

    /// 回数を0へ戻してセッションを開始します。表示要求は変更しません。
    pub fn begin(&self) {
        let shared = &self.shared;
        for count in &shared.counts {
            count.store(0, Ordering::Release);
        }
        shared.highlight.store(0, Ordering::Release);
        shared.session_active.store(true, Ordering::Release);
        shared.heartbeat();
        shared.request_refresh();
    }

    /// 対応する技法だけを飽和加算し、短時間の強調表示を予約します。
    pub fn update(&self, technique_id: i32, value: i32) {
        if value <= 0 {
            return;
        }
        let Some(index) = model::technique_index(technique_id) else {
            return;
        };
        let shared = &self.shared;
        let _ = shared.counts[index].try_update(Ordering::AcqRel, Ordering::Acquire, |current| {
            Some(model::saturating_count(current, value))
        });
        let until = now_ms().saturating_add(model::HIGHLIGHT_MS);
        shared
            .highlight
            .store(model::pack_highlight(Some(index), until), Ordering::Release);
        shared.heartbeat();
        shared.request_refresh();
    }

    /// 現在曲の回数を保ったまま、表示要求だけを切り替えます。
    pub fn set_visible(&self, visible: bool) {
        let shared = &self.shared;
        let session_active = shared.session_active.load(Ordering::Acquire);
        shared
            .requested_visible
            .store(visible && session_active, Ordering::Release);
        shared.heartbeat();
        shared.request_refresh();
    }

    /// 未検出タイルを含めるかを切り替えます。
    pub fn set_show_zero(&self, show_zero: bool) {
        self.shared.show_zero.store(show_zero, Ordering::Release);
        self.shared.heartbeat();
        self.shared.request_refresh();
    }

    /// セッションを閉じて表示を隠します。次の `begin` まで表示要求も解除します。
    pub fn end(&self) {
        let shared = &self.shared;
        shared.session_active.store(false, Ordering::Release);
        shared.requested_visible.store(false, Ordering::Release);
        shared.highlight.store(0, Ordering::Release);
        shared.heartbeat();
        shared.request_refresh();
    }

    /// Agentの生存時刻を更新します。
    pub fn heartbeat(&self) {
        self.shared.heartbeat();
    }

    /// 描画スレッドへ終了を通知し、終了を待ちます。
    ///
    /// 待機を打ち切った場合もスレッドが共有状態を `Arc` で保持し続けるため、解放済み領域へは触れません。
    pub fn stop(mut self) {
        let shared = &self.shared;
        shared.stopping.store(true, Ordering::Release);
        let thread_id = shared.thread_id.load(Ordering::Acquire);
        if thread_id != 0 {
            // SAFETY: 終了要求の非同期投函です。キューが無い場合でも `stopping` を次の周期で確認します。
            let _ = unsafe { PostThreadMessageW(thread_id, WM_QUIT, WPARAM(0), LPARAM(0)) };
        }
        let Some(thread) = self.thread.take() else {
            return;
        };
        let deadline = Instant::now() + STOP_TIMEOUT;
        while !thread.is_finished() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        if thread.is_finished() {
            let _ = thread.join();
        }
        // 終了しなかった場合は JoinHandle を手放してスレッドを切り離します。
    }
}

/// 自プロセスのDAM主要画面候補を、可視・オーナーなし・最大面積で選びます。
struct OwnerSearch {
    process_id: u32,
    best: Option<HWND>,
    best_area: i64,
}

fn window_area(window: HWND) -> i64 {
    let mut rect = RECT::default();
    // SAFETY: 出力先はローカル変数です。
    if unsafe { GetWindowRect(window, &mut rect) }.is_err() {
        return 0;
    }
    i64::from((rect.right - rect.left).max(0)) * i64::from((rect.bottom - rect.top).max(0))
}

unsafe extern "system" fn find_owner_callback(window: HWND, parameter: LPARAM) -> BOOL {
    // SAFETY: `find_owner` が渡した、列挙中だけ有効な `OwnerSearch` です。
    let search = unsafe { &mut *(parameter.0 as *mut OwnerSearch) };
    let mut process_id = 0;
    // SAFETY: 列挙中のウィンドウへの読み取り専用の問い合わせです。
    let eligible = unsafe {
        GetWindowThreadProcessId(window, Some(&mut process_id));
        process_id == search.process_id
            && IsWindowVisible(window).as_bool()
            && GetWindow(window, GW_OWNER).map_or(true, |owner| owner.is_invalid())
    };
    if eligible {
        let area = window_area(window);
        if area > search.best_area {
            search.best = Some(window);
            search.best_area = area;
        }
    }
    BOOL(1)
}

fn find_owner() -> Option<(HWND, i64)> {
    let mut search = OwnerSearch {
        // SAFETY: 引数を取らない単純な問い合わせです。
        process_id: unsafe { GetCurrentProcessId() },
        best: None,
        best_area: 0,
    };
    // SAFETY: コールバックは列挙中だけ `search` を参照します。
    let _ = unsafe {
        EnumWindows(
            Some(find_owner_callback),
            LPARAM(&mut search as *mut OwnerSearch as isize),
        )
    };
    search.best.map(|window| (window, search.best_area))
}

unsafe extern "system" fn window_procedure(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_NCHITTEST => LRESULT(HTTRANSPARENT as isize),
        WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
        // SAFETY: 未処理のメッセージを既定処理へ渡します。
        _ => unsafe { DefWindowProcW(window, message, wparam, lparam) },
    }
}

fn module_handle() -> HINSTANCE {
    let mut module = HMODULE::default();
    // SAFETY: このDLL内の関数アドレスから、参照カウントを変えずにモジュールを求めます。
    let _ = unsafe {
        GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            PCWSTR(window_procedure as *const () as *const u16),
            &mut module,
        )
    };
    module.into()
}

/// 描画スレッドだけが触るウィンドウ状態です。
struct Follower {
    shared: Arc<Shared>,
    renderer: Renderer,
    instance: HINSTANCE,
    class_name: HSTRING,
    owner: Option<HWND>,
    window: Option<HWND>,
    shown: bool,
    last_origin: POINT,
    last_size: (i32, i32),
    ticks: u32,
}

impl Follower {
    fn tick(&mut self) {
        self.ticks = self.ticks.wrapping_add(1);
        self.follow_owner();
        let Some(owner) = self.owner else {
            return;
        };
        if self.window.is_none() && !self.create_window(owner) {
            return;
        }
        let Some(window) = self.window else {
            return;
        };
        let shared = &self.shared;
        let now = now_ms();
        let packed = shared.highlight.load(Ordering::Acquire);
        if let Some((_, until)) = model::unpack_highlight(packed)
            && now >= until
            && shared
                .highlight
                .compare_exchange(packed, 0, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
        {
            shared.dirty.store(true, Ordering::Release);
        }
        let visible = model::is_visible(
            shared.requested_visible.load(Ordering::Acquire),
            shared.session_active.load(Ordering::Acquire),
            now,
            shared.last_heartbeat.load(Ordering::Acquire),
        ) && !shared.stopping.load(Ordering::Acquire);
        // SAFETY: 所有ウィンドウへの読み取り専用の問い合わせです。
        let owner_shown = unsafe { IsWindowVisible(owner).as_bool() && !IsIconic(owner).as_bool() };
        let Some((origin, width, height)) = visible
            .then(|| client_geometry(owner))
            .flatten()
            .filter(|_| owner_shown)
        else {
            self.hide();
            return;
        };
        let geometry_changed = origin != self.last_origin || (width, height) != self.last_size;
        if shared.dirty.swap(false, Ordering::AcqRel) || geometry_changed || !self.shown {
            let counts = shared.snapshot_counts();
            let frame = Frame {
                origin,
                width,
                height,
                counts: &counts,
                show_zero: shared.show_zero.load(Ordering::Acquire),
                highlight: model::unpack_highlight(shared.highlight.load(Ordering::Acquire))
                    .map(|(index, _)| index),
            };
            if self.renderer.render(window, &frame) {
                self.last_origin = origin;
                self.last_size = (width, height);
            } else {
                shared.dirty.store(true, Ordering::Release);
                if !self.shown {
                    return;
                }
            }
        }
        if !self.shown {
            // SAFETY: このスレッドが作成したウィンドウです。
            let _ = unsafe { ShowWindow(window, SW_SHOWNOACTIVATE) };
            self.shown = true;
        }
    }

    fn hide(&mut self) {
        if let Some(window) = self.window
            && self.shown
        {
            // SAFETY: このスレッドが作成したウィンドウです。
            let _ = unsafe { ShowWindow(window, SW_HIDE) };
        }
        self.shown = false;
    }

    /// 所有ウィンドウの破棄・非表示・より大きい主画面の出現を検知し、必要なら作り直します。
    fn follow_owner(&mut self) {
        // 所有ウィンドウが破棄されると、所有されていた描画ウィンドウも一緒に破棄されます。
        if let Some(window) = self.window
            // SAFETY: ハンドルの有効性確認だけを行います。
            && !unsafe { IsWindow(Some(window)) }.as_bool()
        {
            self.window = None;
            self.shown = false;
        }
        let current_valid = self
            .owner
            // SAFETY: ハンドルの有効性・可視性の確認だけを行います。
            .is_some_and(|owner| unsafe {
                IsWindow(Some(owner)).as_bool() && IsWindowVisible(owner).as_bool()
            });
        if current_valid && !self.ticks.is_multiple_of(OWNER_RECHECK_TICKS) {
            return;
        }
        let candidate = find_owner();
        let next = match (self.owner.filter(|_| current_valid), candidate) {
            (Some(current), Some((best, best_area)))
                if best != current && best_area > window_area(current) =>
            {
                Some(best)
            }
            (Some(current), _) => Some(current),
            (None, found) => found.map(|(window, _)| window),
        };
        if next != self.owner {
            self.destroy_window();
            self.owner = next;
        }
    }

    fn create_window(&mut self, owner: HWND) -> bool {
        // SAFETY: このスレッドで登録したクラスから、所有ウィンドウ付きのポップアップを作ります。
        let created = unsafe {
            CreateWindowExW(
                WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                &self.class_name,
                w!(""),
                WS_POPUP,
                0,
                0,
                1,
                1,
                Some(owner),
                None,
                Some(self.instance),
                None,
            )
        };
        match created {
            Ok(window) => {
                self.window = Some(window);
                self.shown = false;
                self.last_size = (0, 0);
                self.shared.dirty.store(true, Ordering::Release);
                true
            }
            Err(_) => false,
        }
    }

    fn destroy_window(&mut self) {
        if let Some(window) = self.window.take() {
            // SAFETY: このスレッドが作成したウィンドウです。既に破棄済みなら失敗するだけです。
            let _ = unsafe { DestroyWindow(window) };
        }
        self.shown = false;
    }
}

/// 所有ウィンドウのクライアント領域の画面座標と大きさを返します。
fn client_geometry(owner: HWND) -> Option<(POINT, i32, i32)> {
    let mut client = RECT::default();
    let mut origin = POINT::default();
    // SAFETY: 出力先はローカル変数です。
    unsafe {
        GetClientRect(owner, &mut client).ok()?;
        origin.x = client.left;
        origin.y = client.top;
        if !ClientToScreen(owner, &mut origin).as_bool() {
            return None;
        }
    }
    let width = client.right - client.left;
    let height = client.bottom - client.top;
    (width > 0 && height > 0).then_some((origin, width, height))
}

fn thread_main(shared: Arc<Shared>, asset_directory: PathBuf, ready: mpsc::Sender<bool>) {
    let mut message = MSG::default();
    // SAFETY: 呼び出しスレッドにメッセージキューを作らせるための問い合わせです。
    unsafe {
        let _ = PeekMessageW(&mut message, None, WM_USER, WM_USER, PM_NOREMOVE);
        shared
            .thread_id
            .store(GetCurrentThreadId(), Ordering::Release);
    }
    // SAFETY: このスレッドで初めてのCOM初期化で、終了時に対で解除します。
    if unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) }.is_err() {
        let _ = ready.send(false);
        return;
    }
    run(&shared, asset_directory, ready);
    // SAFETY: 上の `CoInitializeEx` と対になる解除です。COMオブジェクトは `run` 内で破棄済みです。
    unsafe { CoUninitialize() };
}

fn run(shared: &Arc<Shared>, asset_directory: PathBuf, ready: mpsc::Sender<bool>) {
    let Ok(renderer) = Renderer::new(&asset_directory) else {
        let _ = ready.send(false);
        return;
    };
    let instance = module_handle();
    // SAFETY: 引数を取らない単純な問い合わせです。
    let (process_id, thread_id) = unsafe { (GetCurrentProcessId(), GetCurrentThreadId()) };
    let class_name = HSTRING::from(format!(
        "DAMforWindowsTools.ScoringOverlay.{process_id}.{thread_id}"
    ));
    let class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        lpfnWndProc: Some(window_procedure),
        hInstance: instance,
        lpszClassName: PCWSTR(class_name.as_ptr()),
        ..Default::default()
    };
    // SAFETY: クラス名とウィンドウプロシージャはスレッド終了まで有効です。
    if unsafe { RegisterClassExW(&class) } == 0 {
        let _ = ready.send(false);
        return;
    }
    // SAFETY: スレッドタイマーで、WM_TIMERはこのスレッドのキューへ届きます。
    let timer = unsafe { SetTimer(None, 0, FOLLOW_INTERVAL_MS, None) };
    let mut follower = Follower {
        shared: Arc::clone(shared),
        renderer,
        instance,
        class_name,
        owner: None,
        window: None,
        shown: false,
        last_origin: POINT::default(),
        last_size: (0, 0),
        ticks: 0,
    };
    let _ = ready.send(true);
    follower.tick();

    let mut message = MSG::default();
    // SAFETY: このスレッドのメッセージループです。
    unsafe {
        while GetMessageW(&mut message, None, 0, 0).0 > 0 {
            if shared.stopping.load(Ordering::Acquire) {
                break;
            }
            if message.hwnd.is_invalid()
                && (message.message == WM_TIMER || message.message == REFRESH_MESSAGE)
            {
                shared.refresh_pending.store(false, Ordering::Release);
                follower.tick();
                continue;
            }
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if timer != 0 {
            let _ = KillTimer(None, timer);
        }
    }
    follower.destroy_window();
    let instance = follower.instance;
    let class_name = follower.class_name.clone();
    drop(follower);
    // SAFETY: このスレッドで登録し、ウィンドウを全て破棄済みのクラスです。
    let _ = unsafe { UnregisterClassW(&class_name, Some(instance)) };
}
