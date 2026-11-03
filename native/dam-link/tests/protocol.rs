// dam-link.exe を子プロセスとして起動し、プロトコルを端から端まで試験します。
//
// DAMの代わりに、この試験EXEを一意な名前で複製したもの（`target_sleeper` だけを実行）を対象にし、
// 最小限の試験用Agentを注入します。Fridaの接続・RPC・イベント転送・切断検知・終了処理を確認します。

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

const TEST_AGENT: &str = r#"
let config = null;
rpc.exports = {
  initialize(next) {
    config = next;
    send({ type: 'log', message: `initialized ${DAM_TARGET_MANIFEST.target.processName} ${DAM_RUNTIME_CONFIG.mediaOrigin}` });
    return true;
  },
  updateConfig(next) {
    config = next;
    send({ type: 'log', message: `config replace=${next.replaceVideoUrls}` });
    return true;
  },
  restoreAll() {
    send({ type: 'log', message: 'restored' });
    return true;
  },
  remoteState() {
    return { connected: true, key: 2, replace: config.replaceVideoUrls };
  },
  remoteSearch(requestId, query, mode) {
    setTimeout(() => send({ type: 'remote-search-result', requestId, query, mode, total: 1, rows: [{ title: query }] }), 10);
    return true;
  },
  remoteControl(action) {
    if (action === 'fail') throw new Error('another remote request is running');
    if (action === 'prepare') {
      for (const id of ['p1', 'p2']) {
        recv(`prepare-result:${id}`, (message) => {
          send({ type: 'rewritten', videoId: id, highUrl: message.payload.localUrl, lowUrl: message.payload.error });
        });
        send({ type: 'prepare', requestId: id, videoId: id, highUrl: 'h', lowUrl: 'l' });
      }
    }
    return { action };
  },
};
"#;

/// 接続対象として複製・起動されたときだけ、しばらく待機します。
#[test]
#[ignore]
fn target_sleeper() {
    std::thread::sleep(Duration::from_secs(120));
}

struct Helper {
    child: Child,
    stdin: ChildStdin,
    events: Receiver<Value>,
    seen: Vec<Value>,
}

impl Helper {
    fn start(root: &Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_dam-link"))
            .env("DAM_TOOLS_APP_ROOT", root)
            .env("DAM_TOOLS_MEDIA_ORIGIN", "http://127.0.0.1:8765")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("dam-link を起動できません");
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (sender, events) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let event: Value = serde_json::from_str(&line).expect("JSON以外の行を受信しました");
                if sender.send(event).is_err() {
                    break;
                }
            }
        });
        Self {
            child,
            stdin,
            events,
            seen: Vec::new(),
        }
    }

    fn send(&mut self, command: Value) {
        writeln!(self.stdin, "{command}").unwrap();
        self.stdin.flush().unwrap();
    }

    /// 条件に合うイベントを待ちます。それまでのイベントは `seen` に残します。
    fn wait_for(&mut self, what: &str, predicate: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + Duration::from_secs(30);
        if let Some(index) = self.seen.iter().position(&predicate) {
            return self.seen.remove(index);
        }
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match self.events.recv_timeout(remaining) {
                Ok(event) if predicate(&event) => return event,
                Ok(event) => self.seen.push(event),
                Err(_) => panic!("{what} が届きません。受信済み: {:#?}", self.seen),
            }
        }
    }

    fn wait_status(&mut self, state: &str) -> Value {
        self.wait_for(&format!("status {state}"), |e| {
            e["type"] == "status" && e["state"] == state
        })
    }

    fn wait_log(&mut self, text: &str) -> Value {
        self.wait_for(&format!("log {text}"), |e| {
            e["type"] == "log" && e["message"].as_str().unwrap_or("").contains(text)
        })
    }

    fn wait_result(&mut self, kind: &str, request_id: &str) -> Value {
        self.wait_for(kind, |e| e["type"] == kind && e["requestId"] == request_id)
    }
}

struct Target {
    child: Child,
}

impl Target {
    fn start(exe: &Path) -> Self {
        let child = Command::new(exe)
            .args(["--exact", "target_sleeper", "--ignored", "--test-threads=1"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("対象プロセスを起動できません");
        Self { child }
    }

    fn kill(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for Target {
    fn drop(&mut self) {
        self.kill();
    }
}

fn prepare_root() -> (PathBuf, PathBuf) {
    let root = std::env::temp_dir().join(format!("dam-link-protocol-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let helper = root.join("helper");
    std::fs::create_dir_all(helper.join("agent")).unwrap();
    let target_name = format!("dam-link-target-{}.exe", std::process::id());
    let target_exe = root.join(&target_name);
    std::fs::copy(std::env::current_exe().unwrap(), &target_exe).unwrap();
    let hash = dam_link::discovery::sha256_file(&target_exe).unwrap();
    std::fs::write(
        helper.join("supported-dam.json"),
        json!({ "target": { "processName": target_name, "fileVersion": "test", "sha256": hash } })
            .to_string(),
    )
    .unwrap();
    std::fs::write(helper.join("agent").join("00_test.js"), TEST_AGENT).unwrap();
    (root, target_exe)
}

#[test]
fn speaks_the_protocol_with_a_real_frida_session() {
    let (root, target_exe) = prepare_root();
    let mut helper = Helper::start(&root);

    // 起動直後と、対象が無いとき。
    helper.wait_status("ready");
    helper.wait_status("waiting");
    helper.send(json!({ "type": "config", "replaceVideoUrls": false }));
    helper.send(json!({ "type": "remoteState", "requestId": "a1" }));
    let result = helper.wait_result("remote-state-result", "a1");
    assert_eq!(result["error"], "DAMに接続されていません");
    helper
        .send(json!({ "type": "remoteSearch", "requestId": "a2", "query": "x", "mode": "title" }));
    let result = helper.wait_result("remote-search-result", "a2");
    assert_eq!(result["error"], "DAMに接続されていません");
    assert_eq!(result["rows"], json!([]));

    // 不正な行・巨大な行・不明なコマンドは拒否して続行します。
    writeln!(helper.stdin, "not json").unwrap();
    writeln!(helper.stdin, "{}", "x".repeat(70 * 1024)).unwrap();
    helper.send(json!({ "type": "nope" }));
    helper.wait_log("不正なJSON Linesコマンド");
    helper.wait_log("上限を超えるJSON Linesコマンド");
    helper.wait_log("不明なヘルパーコマンド: nope");

    // 対象を起動すると自動で接続し、保持していた設定で初期化します。
    let mut target = Target::start(&target_exe);
    let attaching = helper.wait_status("attaching");
    assert!(
        attaching["detail"]
            .as_str()
            .unwrap()
            .contains("DAM for Windows test")
    );
    helper.wait_log("initialized dam-link-target-");
    helper.wait_status("attached");
    helper.send(json!({ "type": "remoteState", "requestId": "b1" }));
    let result = helper.wait_result("remote-state-result", "b1");
    assert_eq!(
        result["result"],
        json!({ "connected": true, "key": 2, "replace": false })
    );

    // 設定変更は接続中のAgentへ即時に反映されます。
    helper.send(json!({ "type": "config", "replaceVideoUrls": true }));
    helper.wait_log("config replace=true");

    // 非同期の結果はAgentのイベントとして、同じ requestId で届きます。
    helper.send(
        json!({ "type": "remoteSearch", "requestId": "b2", "query": "abc", "mode": "keyword" }),
    );
    let result = helper.wait_result("remote-search-result", "b2");
    assert_eq!(result["rows"], json!([{ "title": "abc" }]));

    // Agentの例外は error 文字列になります。
    helper.send(json!({ "type": "remoteControl", "requestId": "b3", "action": "fail" }));
    let result = helper.wait_result("remote-control-result", "b3");
    assert_eq!(result["error"], "another remote request is running");

    // prepare: 応答したものはその内容で、応答しないものは1.9秒後に期限切れで返ります。
    helper.send(json!({ "type": "remoteControl", "requestId": "b4", "action": "prepare" }));
    helper.wait_result("remote-control-result", "b4");
    helper.wait_result("prepare", "p1");
    helper.wait_result("prepare", "p2");
    helper.send(json!({
        "type": "prepareResult", "requestId": "p1", "accepted": true,
        "localUrl": "http://127.0.0.1:8765/v/1", "error": "",
    }));
    let rewritten = helper.wait_for("rewritten p1", |e| {
        e["type"] == "rewritten" && e["videoId"] == "p1"
    });
    assert_eq!(rewritten["highUrl"], "http://127.0.0.1:8765/v/1");
    let started = Instant::now();
    let rewritten = helper.wait_for("rewritten p2", |e| {
        e["type"] == "rewritten" && e["videoId"] == "p2"
    });
    assert_eq!(rewritten["lowUrl"], "registration timeout");
    assert!(started.elapsed() < Duration::from_secs(5));

    // 対象が終了したら waiting に戻り、再起動すれば自動で再接続します。
    target.kill();
    let waiting = helper.wait_status("waiting");
    assert!(waiting["detail"].as_str().unwrap().contains("切断"));
    let mut target = Target::start(&target_exe);
    helper.wait_status("attached");

    // reconnect は復元してから接続し直します。
    helper.send(json!({ "type": "reconnect" }));
    helper.wait_log("restored");
    helper.wait_log("initialized dam-link-target-");

    // shutdown は復元してから終了します。
    helper.send(json!({ "type": "shutdown" }));
    helper.wait_log("restored");
    let status = helper.child.wait().unwrap();
    assert_eq!(status.code(), Some(0));
    target.kill();
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn exits_after_stdin_closes() {
    let root = prepare_root_named("eof");
    let mut helper = Helper::start(&root);
    helper.wait_status("ready");
    let Helper {
        mut child, stdin, ..
    } = helper;
    drop(stdin);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert_eq!(status.code(), Some(0));
            break;
        }
        assert!(Instant::now() < deadline, "stdinを閉じても終了しません");
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn refuses_to_start_without_a_loopback_media_origin() {
    let root = prepare_root_named("origin");
    let output = Command::new(env!("CARGO_BIN_EXE_dam-link"))
        .env("DAM_TOOLS_APP_ROOT", &root)
        .env("DAM_TOOLS_MEDIA_ORIGIN", "http://example.com")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("DAM_TOOLS_MEDIA_ORIGIN"));
    let _ = std::fs::remove_dir_all(&root);
}

/// 対象を起動しない試験用です。存在しないプロセス名を対象にします。
fn prepare_root_named(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("dam-link-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let helper = root.join("helper");
    std::fs::create_dir_all(helper.join("agent")).unwrap();
    std::fs::write(
        helper.join("supported-dam.json"),
        json!({ "target": { "processName": "no-such-dam.exe", "fileVersion": "test", "sha256": "0".repeat(64) } })
            .to_string(),
    )
    .unwrap();
    std::fs::write(helper.join("agent").join("00_test.js"), TEST_AGENT).unwrap();
    root
}
