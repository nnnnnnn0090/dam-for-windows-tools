//! 1つのAgentスクリプトとの通信です。RPCの対応付け、イベントの転送、URL登録要求の期限を扱います。

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, SyncSender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use serde_json::{Value, json};

use crate::frida::Script;
use crate::protocol::Protocol;

/// 未接続・切断時の共通メッセージです。アプリはこの文言で `notConnected` に分類します。
pub const NOT_CONNECTED: &str = "DAMに接続されていません";

/// `prepare` への応答をアプリから待つ上限です。過ぎたら公式URLを使わせます。
pub const PREPARE_TIMEOUT: Duration = Duration::from_millis(1900);

/// Agentへ転送してよいイベントの種別です。
const FORWARDED_EVENTS: [&str; 9] = [
    "playback",
    "rewritten",
    "scoring-start",
    "scoring-technique",
    "scoring-stop",
    "remote-search-result",
    "remote-detail-result",
    "remote-reserve-result",
    "remote-favorite-result",
];

type RpcReply = Result<Value, String>;

#[derive(Default)]
struct RpcState {
    next_id: u64,
    pending: HashMap<u64, SyncSender<RpcReply>>,
    closed: bool,
}

pub struct AgentChannel {
    protocol: Arc<Protocol>,
    script: Mutex<Option<Script>>,
    rpc: Mutex<RpcState>,
    preparations: Mutex<HashSet<String>>,
    /// 初期化が済み、アプリへ `attached` を通知した状態です。
    active: AtomicBool,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl AgentChannel {
    pub fn new(protocol: Arc<Protocol>) -> Arc<Self> {
        Arc::new(Self {
            protocol,
            script: Mutex::new(None),
            rpc: Mutex::new(RpcState::default()),
            preparations: Mutex::new(HashSet::new()),
            active: AtomicBool::new(false),
        })
    }

    pub fn set_script(&self, script: Script) {
        *lock(&self.script) = Some(script);
    }

    pub fn script(&self) -> Option<Script> {
        lock(&self.script).clone()
    }

    pub fn set_active(&self, active: bool) -> bool {
        self.active.swap(active, Ordering::SeqCst)
    }

    pub fn is_closed(&self) -> bool {
        lock(&self.rpc).closed
    }

    /// 待機中のRPCをすべて失敗にし、以後の送信を止めます。スクリプトへの参照も手放します。
    pub fn close(&self) {
        let pending = {
            let mut rpc = lock(&self.rpc);
            rpc.closed = true;
            std::mem::take(&mut rpc.pending)
        };
        for reply in pending.into_values() {
            let _ = reply.try_send(Err(NOT_CONNECTED.into()));
        }
        lock(&self.preparations).clear();
        lock(&self.script).take();
    }

    fn post(&self, message: &Value) {
        if let Some(script) = lock(&self.script).as_ref() {
            script.post(&message.to_string());
        }
    }

    /// `rpc.exports` の関数を呼び、結果を待ちます。
    ///
    /// 応答はメッセージのコールバックの中で直接解決するため、
    /// 受信処理と応答待ちがお互いを待ち合うことはありません。
    pub fn call(&self, method: &str, arguments: Value, timeout: Duration) -> RpcReply {
        let (sender, receiver) = mpsc::sync_channel(1);
        let id = {
            let mut rpc = lock(&self.rpc);
            if rpc.closed {
                return Err(NOT_CONNECTED.into());
            }
            rpc.next_id += 1;
            let id = rpc.next_id;
            rpc.pending.insert(id, sender);
            id
        };
        self.post(&json!(["frida:rpc", id, "call", method, arguments]));
        match receiver.recv_timeout(timeout) {
            Ok(reply) => reply,
            Err(RecvTimeoutError::Timeout) => {
                lock(&self.rpc).pending.remove(&id);
                Err(format!("Agentの応答がタイムアウトしました ({method})"))
            }
            Err(RecvTimeoutError::Disconnected) => Err(NOT_CONNECTED.into()),
        }
    }

    /// Fridaから届いたメッセージを処理します。Fridaのスレッドから呼ばれます。
    pub fn handle_message(self: &Arc<Self>, raw: &str) {
        let Ok(message) = serde_json::from_str::<Value>(raw) else {
            self.protocol.log("Agentから不正なメッセージを受信しました");
            return;
        };
        match message["type"].as_str() {
            Some("send") => self.handle_send(message["payload"].clone()),
            Some("error") => self.protocol.log(format!(
                "Frida agent error: {}",
                message["description"].as_str().unwrap_or("unknown error")
            )),
            Some("log") => self.protocol.log(format!(
                "agent: {}",
                message["payload"].as_str().unwrap_or("")
            )),
            _ => {}
        }
    }

    fn handle_send(self: &Arc<Self>, payload: Value) {
        if let Some(items) = payload.as_array()
            && items.first().and_then(Value::as_str) == Some("frida:rpc")
        {
            self.resolve_rpc(items);
            return;
        }
        let Some(kind) = payload["type"].as_str() else {
            return;
        };
        match kind {
            "log" => self
                .protocol
                .log(payload["message"].as_str().unwrap_or("").to_owned()),
            "patch-error" => self.protocol.emit(&json!({
                "type": "patch-error",
                "message": payload["message"].as_str().unwrap_or(""),
            })),
            "metadata" => self.protocol.emit(&json!({
                "type": "metadata",
                "candidates": payload.get("candidates").cloned().unwrap_or_else(|| json!([])),
            })),
            "prepare" => self.begin_preparation(payload),
            _ if FORWARDED_EVENTS.contains(&kind) => self.protocol.emit(&payload),
            _ => self.protocol.log(format!("未処理のAgentイベント: {kind}")),
        }
    }

    /// `["frida:rpc", id, "ok", value]` または `["frida:rpc", id, "error", message, ...]` です。
    fn resolve_rpc(&self, items: &[Value]) {
        let Some(id) = items.get(1).and_then(Value::as_u64) else {
            return;
        };
        let Some(reply) = lock(&self.rpc).pending.remove(&id) else {
            return;
        };
        let result = match items.get(2).and_then(Value::as_str) {
            Some("ok") => Ok(items.get(3).cloned().unwrap_or(Value::Null)),
            _ => Err(items
                .get(3)
                .and_then(Value::as_str)
                .unwrap_or("Agentの呼び出しに失敗しました")
                .to_owned()),
        };
        let _ = reply.try_send(result);
    }

    /// URL登録要求をアプリへ渡し、期限内に応答がなければ公式URLを使わせます。
    fn begin_preparation(self: &Arc<Self>, payload: Value) {
        let Some(request_id) = payload["requestId"]
            .as_str()
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
        else {
            return;
        };
        lock(&self.preparations).insert(request_id.clone());
        self.protocol.emit(&payload);
        let channel = Arc::downgrade(self);
        let spawned = std::thread::Builder::new()
            .name("prepare-timeout".into())
            .spawn(move || {
                std::thread::sleep(PREPARE_TIMEOUT);
                if let Some(channel) = channel.upgrade() {
                    channel.answer_preparation(&request_id, false, "", "registration timeout");
                }
            });
        if spawned.is_err() {
            self.protocol.log("URL登録の期限タイマーを開始できません");
        }
    }

    /// アプリの `prepareResult` を、待機中のAgentへ返します。
    pub fn respond_to_preparation(&self, command: &Value) {
        let Some(request_id) = command["requestId"].as_str() else {
            return;
        };
        self.answer_preparation(
            request_id,
            command["accepted"] == Value::Bool(true),
            command["localUrl"].as_str().unwrap_or(""),
            command["error"].as_str().unwrap_or(""),
        );
    }

    fn answer_preparation(&self, request_id: &str, accepted: bool, local_url: &str, error: &str) {
        if !lock(&self.preparations).remove(request_id) {
            return;
        }
        self.post(&json!({
            "type": format!("prepare-result:{request_id}"),
            "payload": { "accepted": accepted, "localUrl": local_url, "error": error },
        }));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn channel() -> Arc<AgentChannel> {
        AgentChannel::new(Arc::new(Protocol::new(Box::new(std::io::sink()))))
    }

    #[test]
    fn rpc_reply_is_resolved_from_message_callback() {
        let channel = channel();
        let caller = {
            let channel = channel.clone();
            std::thread::spawn(move || {
                channel.call("remoteState", json!([]), Duration::from_secs(5))
            })
        };
        // 送信前に応答が来ても取りこぼさないよう、登録を待ってから返します。
        while lock(&channel.rpc).pending.is_empty() {
            std::thread::yield_now();
        }
        channel.handle_message(
            &json!({"type": "send", "payload": ["frida:rpc", 1, "ok", {"key": 2}]}).to_string(),
        );
        assert_eq!(caller.join().unwrap().unwrap(), json!({"key": 2}));
    }

    #[test]
    fn rpc_error_carries_agent_message() {
        let channel = channel();
        let caller = {
            let channel = channel.clone();
            std::thread::spawn(move || {
                channel.call("remoteSearch", json!([]), Duration::from_secs(5))
            })
        };
        while lock(&channel.rpc).pending.is_empty() {
            std::thread::yield_now();
        }
        channel.handle_message(
            &json!({"type": "send", "payload": ["frida:rpc", 1, "error", "another remote request is running", "Error"]}).to_string(),
        );
        assert_eq!(
            caller.join().unwrap().unwrap_err(),
            "another remote request is running"
        );
    }

    #[test]
    fn close_fails_pending_and_later_calls() {
        let channel = channel();
        let caller = {
            let channel = channel.clone();
            std::thread::spawn(move || {
                channel.call("remoteQueue", json!([]), Duration::from_secs(30))
            })
        };
        while lock(&channel.rpc).pending.is_empty() {
            std::thread::yield_now();
        }
        channel.close();
        assert_eq!(caller.join().unwrap().unwrap_err(), NOT_CONNECTED);
        assert_eq!(
            channel
                .call("remoteQueue", json!([]), Duration::from_secs(1))
                .unwrap_err(),
            NOT_CONNECTED
        );
    }

    #[test]
    fn preparation_is_answered_only_once() {
        let channel = channel();
        channel.handle_message(
            &json!({"type": "send", "payload": {"type": "prepare", "requestId": "1-1"}})
                .to_string(),
        );
        assert!(lock(&channel.preparations).contains("1-1"));
        channel.respond_to_preparation(&json!({"requestId": "1-1", "accepted": true}));
        assert!(lock(&channel.preparations).is_empty());
    }
}
