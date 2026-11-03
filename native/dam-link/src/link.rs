//! DAMの探索・検証・接続・切断です。`docs/DAM_LINK_DESIGN.md` の4章に従います。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, TryLockError};
use std::time::Duration;

use serde_json::{Value, json};

use crate::agent::{AgentChannel, NOT_CONNECTED};
use crate::config::{FeatureConfig, TargetConfig};
use crate::discovery::{HashCache, executable_path, find_process};
use crate::frida::{Runtime, Session};
use crate::protocol::Protocol;

const INITIALIZE_TIMEOUT: Duration = Duration::from_secs(30);
const RESTORE_TIMEOUT: Duration = Duration::from_secs(4);
const CONFIG_TIMEOUT: Duration = Duration::from_secs(10);

/// 接続中のDAM1件分です。
pub struct Attachment {
    session: Session,
    channel: Arc<AgentChannel>,
}

impl Attachment {
    pub fn call(&self, method: &str, arguments: Value, timeout: Duration) -> Result<Value, String> {
        self.channel.call(method, arguments, timeout)
    }

    fn is_alive(&self) -> bool {
        !self.channel.is_closed() && !self.session.is_detached()
    }
}

pub struct Link {
    protocol: Arc<Protocol>,
    target: TargetConfig,
    config: Mutex<FeatureConfig>,
    attachment: Mutex<Option<Arc<Attachment>>>,
    /// 接続・切断の手順を1つずつにします。
    sequence: Mutex<()>,
    hashes: Mutex<HashCache>,
    shutting_down: AtomicBool,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Link {
    pub fn new(protocol: Arc<Protocol>, target: TargetConfig) -> Self {
        Self {
            protocol,
            target,
            config: Mutex::new(FeatureConfig::default()),
            attachment: Mutex::new(None),
            sequence: Mutex::new(()),
            hashes: Mutex::new(HashCache::default()),
            shutting_down: AtomicBool::new(false),
        }
    }

    /// 接続中のAgentを返します。切断済みなら `None` です。
    pub fn attachment(&self) -> Option<Arc<Attachment>> {
        lock(&self.attachment)
            .as_ref()
            .filter(|a| a.is_alive())
            .cloned()
    }

    pub fn respond_to_preparation(&self, command: &Value) {
        if let Some(attachment) = self.attachment() {
            attachment.channel.respond_to_preparation(command);
        }
    }

    /// 最新の機能設定を保持し、接続中なら即時に反映します。
    pub fn update_config(&self, command: &Value) {
        let config = FeatureConfig::from_command(command);
        *lock(&self.config) = config;
        if let Some(attachment) = self.attachment()
            && let Err(error) =
                attachment.call("updateConfig", json!([config.to_json()]), CONFIG_TIMEOUT)
        {
            self.protocol
                .log(format!("機能設定を反映できません: {error}"));
        }
    }

    /// 定期監視から呼ばれます。接続処理中なら何もしません。
    pub fn ensure_attached(&self) {
        if self.shutting_down.load(Ordering::SeqCst) {
            return;
        }
        let _guard = match self.sequence.try_lock() {
            Ok(guard) => guard,
            Err(TryLockError::Poisoned(poisoned)) => poisoned.into_inner(),
            Err(TryLockError::WouldBlock) => return,
        };
        self.ensure_attached_locked();
    }

    /// 切断してから、すぐに再探索します。
    pub fn reconnect(&self) {
        let _guard = lock(&self.sequence);
        self.detach_locked();
        self.ensure_attached_locked();
    }

    /// DAMに適用した変更を復元して切断します。以後は再接続しません。
    pub fn shutdown(&self) {
        self.shutting_down.store(true, Ordering::SeqCst);
        let _guard = lock(&self.sequence);
        self.detach_locked();
    }

    fn ensure_attached_locked(&self) {
        if self.shutting_down.load(Ordering::SeqCst) {
            return;
        }
        {
            let mut current = lock(&self.attachment);
            match current.as_ref() {
                Some(attachment) if attachment.is_alive() => return,
                Some(attachment) => {
                    attachment.channel.close();
                    *current = None;
                }
                None => {}
            }
        }
        let process_name = &self.target.process_name;
        let pid = match find_process(process_name) {
            Ok(Some(pid)) => pid,
            Ok(None) => {
                self.protocol
                    .status("waiting", format!("{process_name} の起動を待っています"));
                return;
            }
            Err(error) => {
                self.protocol.log(format!("監視失敗: {error}"));
                return;
            }
        };
        let Ok(path) = executable_path(pid) else {
            self.protocol
                .status("unsupported", "DAM実行ファイルのパスを確認できません");
            return;
        };
        let hash = match lock(&self.hashes).sha256(&path) {
            Ok(hash) => hash,
            Err(_) => {
                self.protocol
                    .status("unsupported", "DAM実行ファイルのパスを確認できません");
                return;
            }
        };
        let label = &self.target.label;
        if hash != self.target.supported_hash {
            self.protocol.status(
                "unsupported",
                format!(
                    "未対応のDAMです。{label}のSHA-256と一致しません ({}…)",
                    &hash[..12]
                ),
            );
            return;
        }

        self.protocol
            .status("attaching", format!("{label} (PID {pid}) へ接続中"));
        match self.attach(pid) {
            Ok(attachment) => {
                *lock(&self.attachment) = Some(attachment);
                self.protocol
                    .status("attached", format!("{label} 接続済み (PID {pid})"));
            }
            Err(error) => {
                self.protocol
                    .status("attach-error", format!("DAM接続失敗: {error}"));
            }
        }
    }

    fn attach(&self, pid: u32) -> Result<Arc<Attachment>, String> {
        let session = Runtime::get()?.attach(pid)?;
        let channel = AgentChannel::new(self.protocol.clone());
        {
            let channel = channel.clone();
            let protocol = self.protocol.clone();
            session.on_detached(move |reason| {
                if channel.set_active(false) {
                    protocol.status("waiting", format!("DAMから切断されました: {reason}"));
                }
                channel.close();
            });
        }
        let attachment = Arc::new(Attachment { session, channel });
        match self.load_agent(&attachment) {
            Ok(()) => Ok(attachment),
            Err(error) => {
                Self::release(&attachment);
                Err(error)
            }
        }
    }

    fn load_agent(&self, attachment: &Attachment) -> Result<(), String> {
        let script = attachment
            .session
            .create_script("dam-for-windows-tools-agent", &self.target.agent_source)?;
        {
            let channel = Arc::downgrade(&attachment.channel);
            script.on_message(move |message| {
                if let Some(channel) = channel.upgrade() {
                    channel.handle_message(message);
                }
            });
        }
        attachment.channel.set_script(script.clone());
        script.load()?;
        let mut applied = *lock(&self.config);
        attachment.call("initialize", json!([applied.to_json()]), INITIALIZE_TIMEOUT)?;
        // 接続処理中に届いた設定を取りこぼさないよう、最新と違えば送り直します。
        loop {
            let latest = *lock(&self.config);
            if latest == applied {
                break;
            }
            attachment.call("updateConfig", json!([latest.to_json()]), CONFIG_TIMEOUT)?;
            applied = latest;
        }
        attachment.channel.set_active(true);
        Ok(())
    }

    fn detach_locked(&self) {
        let attachment = lock(&self.attachment).take();
        if let Some(attachment) = attachment {
            Self::release(&attachment);
        }
    }

    /// パッチ復元、スクリプト破棄、セッション切断の順に解放します。
    fn release(attachment: &Attachment) {
        attachment.channel.set_active(false);
        if !attachment.channel.is_closed() {
            // DAMが既に終了している場合は復元先がないため、失敗しても解放を続けます。
            let _ = attachment.call("restoreAll", json!([]), RESTORE_TIMEOUT);
        }
        if let Some(script) = attachment.channel.script() {
            script.unload();
        }
        attachment.session.detach();
        attachment.channel.close();
    }
}

/// 接続中でなければ共通のエラーを返します。
pub fn require(attachment: Option<Arc<Attachment>>) -> Result<Arc<Attachment>, String> {
    attachment.ok_or_else(|| NOT_CONNECTED.to_owned())
}
