//! frida-core devkit の必要な関数だけを手書きで宣言した、最小限の安全な包みです。
//!
//! `frida` クレート（bindgen と libclang が必要）は使いません。
//! シグナルのコールバックはFridaのスレッドから呼ばれます。コールバックの中では
//! 待ち合わせ（`*_sync` 呼び出しやロックの長時間保持）をしないでください。

use std::ffi::{CStr, CString, c_char, c_int, c_uint, c_ulong, c_void};
use std::ptr::{self, NonNull};
use std::sync::OnceLock;

#[repr(C)]
struct GError {
    domain: u32,
    code: c_int,
    message: *mut c_char,
}

type GDestroyNotify = unsafe extern "C" fn(data: *mut c_void, closure: *mut c_void);

const FRIDA_DEVICE_TYPE_LOCAL: c_int = 0;

unsafe extern "C" {
    fn frida_init();
    fn frida_unref(object: *mut c_void);
    fn frida_device_manager_new() -> *mut c_void;
    fn frida_device_manager_get_device_by_type_sync(
        manager: *mut c_void,
        device_type: c_int,
        timeout: c_int,
        cancellable: *mut c_void,
        error: *mut *mut GError,
    ) -> *mut c_void;
    fn frida_device_attach_sync(
        device: *mut c_void,
        pid: c_uint,
        options: *mut c_void,
        cancellable: *mut c_void,
        error: *mut *mut GError,
    ) -> *mut c_void;
    fn frida_session_is_detached(session: *mut c_void) -> c_int;
    fn frida_session_detach_sync(
        session: *mut c_void,
        cancellable: *mut c_void,
        error: *mut *mut GError,
    );
    fn frida_session_create_script_sync(
        session: *mut c_void,
        source: *const c_char,
        options: *mut c_void,
        cancellable: *mut c_void,
        error: *mut *mut GError,
    ) -> *mut c_void;
    fn frida_script_options_new() -> *mut c_void;
    fn frida_script_options_set_name(options: *mut c_void, name: *const c_char);
    fn frida_script_load_sync(
        script: *mut c_void,
        cancellable: *mut c_void,
        error: *mut *mut GError,
    );
    fn frida_script_unload_sync(
        script: *mut c_void,
        cancellable: *mut c_void,
        error: *mut *mut GError,
    );
    fn frida_script_post(script: *mut c_void, json: *const c_char, data: *mut c_void);
    fn g_object_ref(object: *mut c_void) -> *mut c_void;
    fn g_error_free(error: *mut GError);
    fn g_signal_connect_data(
        instance: *mut c_void,
        detailed_signal: *const c_char,
        handler: *const c_void,
        data: *mut c_void,
        destroy_data: Option<GDestroyNotify>,
        connect_flags: c_int,
    ) -> c_ulong;
    fn g_main_loop_new(context: *mut c_void, is_running: c_int) -> *mut c_void;
    fn g_main_loop_run(main_loop: *mut c_void);
}

/// GObject への所有参照です。破棄時に参照を1つ返します。
struct Object(NonNull<c_void>);

// SAFETY: GObject の参照カウントはスレッド安全で、Fridaの公開APIは任意のスレッドから呼べます。
unsafe impl Send for Object {}
// SAFETY: 同上。
unsafe impl Sync for Object {}

impl Object {
    fn new(pointer: *mut c_void) -> Option<Self> {
        NonNull::new(pointer).map(Self)
    }

    fn as_ptr(&self) -> *mut c_void {
        self.0.as_ptr()
    }
}

impl Clone for Object {
    fn clone(&self) -> Self {
        // SAFETY: 生存中のオブジェクトへの参照を1つ増やします。
        unsafe { g_object_ref(self.as_ptr()) };
        Self(self.0)
    }
}

impl Drop for Object {
    fn drop(&mut self) {
        // SAFETY: new/clone で得た参照を1つだけ返します。
        unsafe { frida_unref(self.as_ptr()) };
    }
}

/// `GError**` を受け取る呼び出しを包み、エラーを文字列にします。
fn call<T>(f: impl FnOnce(*mut *mut GError) -> T) -> Result<T, String> {
    let mut error: *mut GError = ptr::null_mut();
    let value = f(&mut error);
    if error.is_null() {
        return Ok(value);
    }
    // SAFETY: Fridaが設定した GError で、message はNUL終端のUTF-8です。ここで一度だけ解放します。
    let message = unsafe {
        let message = CStr::from_ptr((*error).message)
            .to_string_lossy()
            .into_owned();
        g_error_free(error);
        message
    };
    Err(message)
}

/// Fridaの初期化と、ローカルデバイスです。プロセスにつき1つだけ作ります。
pub struct Runtime {
    device: Object,
}

impl Runtime {
    pub fn get() -> Result<&'static Runtime, String> {
        static RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();
        RUNTIME
            .get_or_init(Self::create)
            .as_ref()
            .map_err(Clone::clone)
    }

    fn create() -> Result<Self, String> {
        // SAFETY: 引数のない初期化関数で、OnceLock により一度だけ呼ばれます。
        unsafe { frida_init() };
        // シグナルが既定のメインコンテキストへ配送される場合に備えて、専用スレッドで回します。
        std::thread::Builder::new()
            .name("glib-main".into())
            .spawn(|| {
                // SAFETY: 既定コンテキストのループを作り、このスレッドで回し続けます（解放しません）。
                unsafe { g_main_loop_run(g_main_loop_new(ptr::null_mut(), 1)) };
            })
            .map_err(|e| format!("GLibのスレッドを開始できません: {e}"))?;
        // SAFETY: 戻り値は Object で所有します。マネージャーはプロセス終了まで保持します。
        let manager = Object::new(unsafe { frida_device_manager_new() })
            .ok_or("Fridaのデバイスマネージャーを作れません")?;
        let device = call(|error| {
            // SAFETY: manager は生存中で、error は call が用意した書き込み先です。
            unsafe {
                frida_device_manager_get_device_by_type_sync(
                    manager.as_ptr(),
                    FRIDA_DEVICE_TYPE_LOCAL,
                    5000,
                    ptr::null_mut(),
                    error,
                )
            }
        })?;
        let device = Object::new(device).ok_or("Fridaのローカルデバイスがありません")?;
        std::mem::forget(manager);
        Ok(Self { device })
    }

    pub fn attach(&self, pid: u32) -> Result<Session, String> {
        let session = call(|error| {
            // SAFETY: device は生存中で、オプションとキャンセルは省略（NULL）です。
            unsafe {
                frida_device_attach_sync(
                    self.device.as_ptr(),
                    pid,
                    ptr::null_mut(),
                    ptr::null_mut(),
                    error,
                )
            }
        })?;
        Object::new(session)
            .map(Session)
            .ok_or_else(|| "Fridaのセッションを作れません".into())
    }
}

/// 接続先プロセスとのセッションです。
pub struct Session(Object);

impl Session {
    pub fn is_detached(&self) -> bool {
        // SAFETY: 生存中のセッションです。
        unsafe { frida_session_is_detached(self.0.as_ptr()) != 0 }
    }

    /// 切断されたときに、理由（`process-terminated` など）を受け取ります。
    pub fn on_detached(&self, handler: impl Fn(&str) + Send + Sync + 'static) {
        type Handler = Box<dyn Fn(&str) + Send + Sync>;
        unsafe extern "C" fn trampoline(
            _session: *mut c_void,
            reason: c_int,
            _crash: *mut c_void,
            data: *mut c_void,
        ) {
            let reason = match reason {
                1 => "application-requested",
                2 => "process-replaced",
                3 => "process-terminated",
                4 => "connection-terminated",
                5 => "device-lost",
                _ => "unknown",
            };
            // SAFETY: data は connect で渡した Handler で、destroy まで生存します。
            let handler = unsafe { &*(data as *const Handler) };
            handler(reason);
        }
        let boxed: Box<Handler> = Box::new(Box::new(handler));
        // SAFETY: シグナルの引数並びは frida-core.h の "detached" と一致します。
        unsafe {
            connect(
                &self.0,
                c"detached",
                trampoline as *const c_void,
                Box::into_raw(boxed).cast(),
                drop_box::<Handler>,
            )
        };
    }

    pub fn create_script(&self, name: &str, source: &str) -> Result<Script, String> {
        let name = CString::new(name).map_err(|_| "スクリプト名が不正です")?;
        let source = CString::new(source).map_err(|_| "AgentソースにNUL文字があります")?;
        // SAFETY: オプションを作って名前を設定します。所有は Object が持ちます。
        let options = Object::new(unsafe { frida_script_options_new() })
            .ok_or("スクリプトのオプションを作れません")?;
        // SAFETY: options と name は生存中です。
        unsafe { frida_script_options_set_name(options.as_ptr(), name.as_ptr()) };
        let script = call(|error| {
            // SAFETY: 各引数は呼び出しの間生存しています。
            unsafe {
                frida_session_create_script_sync(
                    self.0.as_ptr(),
                    source.as_ptr(),
                    options.as_ptr(),
                    ptr::null_mut(),
                    error,
                )
            }
        })?;
        Object::new(script)
            .map(Script)
            .ok_or_else(|| "スクリプトを作れません".into())
    }

    pub fn detach(&self) {
        let _ = call(|error| {
            // SAFETY: 生存中のセッションです。
            unsafe { frida_session_detach_sync(self.0.as_ptr(), ptr::null_mut(), error) }
        });
    }
}

/// 注入したAgentスクリプトです。
#[derive(Clone)]
pub struct Script(Object);

impl Script {
    /// Agentからのメッセージ（JSON文字列）を受け取ります。
    pub fn on_message(&self, handler: impl Fn(&str) + Send + Sync + 'static) {
        type Handler = Box<dyn Fn(&str) + Send + Sync>;
        unsafe extern "C" fn trampoline(
            _script: *mut c_void,
            message: *const c_char,
            _data: *mut c_void,
            data: *mut c_void,
        ) {
            if message.is_null() {
                return;
            }
            // SAFETY: message はシグナル発行中に有効なNUL終端文字列です。
            let message = unsafe { CStr::from_ptr(message) }.to_string_lossy();
            // SAFETY: data は connect で渡した Handler で、destroy まで生存します。
            let handler = unsafe { &*(data as *const Handler) };
            handler(&message);
        }
        let boxed: Box<Handler> = Box::new(Box::new(handler));
        // SAFETY: シグナルの引数並びは frida-core.h の "message" と一致します。
        unsafe {
            connect(
                &self.0,
                c"message",
                trampoline as *const c_void,
                Box::into_raw(boxed).cast(),
                drop_box::<Handler>,
            )
        };
    }

    pub fn load(&self) -> Result<(), String> {
        call(|error| {
            // SAFETY: 生存中のスクリプトです。
            unsafe { frida_script_load_sync(self.0.as_ptr(), ptr::null_mut(), error) }
        })
    }

    pub fn unload(&self) {
        let _ = call(|error| {
            // SAFETY: 生存中のスクリプトです。
            unsafe { frida_script_unload_sync(self.0.as_ptr(), ptr::null_mut(), error) }
        });
    }

    /// Agentへメッセージを送ります。待ち合わせはしません。
    pub fn post(&self, json: &str) {
        let Ok(json) = CString::new(json) else { return };
        // SAFETY: 生存中のスクリプトと、NUL終端文字列です。バイナリデータは送りません。
        unsafe { frida_script_post(self.0.as_ptr(), json.as_ptr(), ptr::null_mut()) };
    }
}

/// # Safety
/// `handler` は `signal` の引数並びに一致する関数、`data` は `destroy` で解放できる値であること。
unsafe fn connect(
    object: &Object,
    signal: &CStr,
    handler: *const c_void,
    data: *mut c_void,
    destroy: GDestroyNotify,
) {
    // SAFETY: 呼び出し元の約束どおりです。data の解放はシグナル切断時に GLib が行います。
    unsafe {
        g_signal_connect_data(
            object.as_ptr(),
            signal.as_ptr(),
            handler,
            data,
            Some(destroy),
            0,
        )
    };
}

unsafe extern "C" fn drop_box<T>(data: *mut c_void, _closure: *mut c_void) {
    // SAFETY: connect で Box::into_raw した値を、GLib が一度だけ返します。
    drop(unsafe { Box::from_raw(data as *mut T) });
}
