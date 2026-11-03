//! DAMへ接続する接続ヘルパー `dam-link.exe` です。Node.js版（`helper/`）の置き換えで、
//! アプリとのプロトコルは `docs/DAM_LINK_DESIGN.md` の3章と完全に同じです。
//!
//! スレッド構成:
//! - メイン: 標準入力を読み、コマンドを振り分けます。`prepareResult` はその場で返します。
//! - control: `config`・`reconnect`・`shutdown` を届いた順に1つずつ処理します。
//! - monitor: 750msごとにDAMを探索し、未接続なら接続します。
//! - 要求ごとのスレッド: `remote*` をAgentへ転送し、結果を返します。

pub mod agent;
pub mod config;
pub mod discovery;
pub mod frida;
pub mod link;
pub mod protocol;
pub mod router;

use std::io;
use std::sync::Arc;
use std::sync::mpsc;
use std::time::Duration;

use serde_json::Value;

use crate::config::{Environment, TargetConfig, locate_agent};
use crate::link::Link;
use crate::protocol::{Line, MAX_COMMAND_LINE_BYTES, Protocol};

const POLL_INTERVAL: Duration = Duration::from_millis(750);

enum Control {
    Config(Value),
    Reconnect,
    Shutdown,
}

/// 終了コードを返します（0: 正常終了, 2: 起動できない構成）。
pub fn run() -> u8 {
    let protocol = Arc::new(Protocol::stdout());
    let exe_dir = match std::env::current_exe() {
        Ok(exe) => exe.parent().map(|p| p.to_path_buf()).unwrap_or_default(),
        Err(error) => {
            eprintln!("dam-link: 実行ファイルの場所を確認できません: {error}");
            return 2;
        }
    };
    let environment = Environment::from_process();
    let target = match locate_agent(&exe_dir, environment.app_root.as_deref())
        .and_then(|files| TargetConfig::load(&files, &environment))
    {
        Ok(target) => target,
        Err(error) => {
            eprintln!("dam-link: {error}");
            return 2;
        }
    };
    if let Err(error) = frida::Runtime::get() {
        eprintln!("dam-link: Fridaを初期化できません: {error}");
        return 2;
    }
    let link = Arc::new(Link::new(protocol.clone(), target));

    let (control, requests) = mpsc::channel::<Control>();
    let control_thread = {
        let link = link.clone();
        std::thread::Builder::new()
            .name("control".into())
            .spawn(move || {
                for request in requests {
                    match request {
                        Control::Config(command) => link.update_config(&command),
                        Control::Reconnect => link.reconnect(),
                        Control::Shutdown => {
                            link.shutdown();
                            std::process::exit(0);
                        }
                    }
                }
            })
            .expect("control スレッドを開始できません")
    };

    protocol.status("ready", "接続ヘルパー起動済み (dam-link)");
    {
        let link = link.clone();
        std::thread::Builder::new()
            .name("monitor".into())
            .spawn(move || {
                loop {
                    link.ensure_attached();
                    std::thread::sleep(POLL_INTERVAL);
                }
            })
            .expect("monitor スレッドを開始できません");
    }

    let read = protocol::read_lines(io::stdin().lock(), MAX_COMMAND_LINE_BYTES, |line| {
        let text = match line {
            Line::TooLong => {
                protocol.log("上限を超えるJSON Linesコマンドを拒否しました");
                return;
            }
            Line::Text(text) if text.trim().is_empty() => return,
            Line::Text(text) => text,
        };
        let command = match serde_json::from_str::<Value>(&text) {
            Ok(command) if command.is_object() => command,
            _ => {
                protocol.log("不正なJSON Linesコマンドを拒否しました");
                return;
            }
        };
        let kind = command["type"].as_str().unwrap_or("").to_owned();
        match kind.as_str() {
            "config" => {
                let _ = control.send(Control::Config(command));
            }
            "reconnect" => {
                let _ = control.send(Control::Reconnect);
            }
            "shutdown" => {
                let _ = control.send(Control::Shutdown);
            }
            "prepareResult" => link.respond_to_preparation(&command),
            _ if router::is_remote_request(&kind) => {
                let link = link.clone();
                let output = protocol.clone();
                let spawned = std::thread::Builder::new()
                    .name(kind.clone())
                    .spawn(move || router::handle_remote_request(&link, &output, &command));
                if spawned.is_err() {
                    protocol.log(format!("コマンド処理失敗: {kind}"));
                }
            }
            _ => protocol.log(format!(
                "不明なヘルパーコマンド: {}",
                if kind.is_empty() { "unknown" } else { &kind }
            )),
        }
    });
    if let Err(error) = read {
        protocol.log(format!("標準入力の読み取りに失敗しました: {error}"));
    }
    // stdinのEOFも `shutdown` と同じ処理にします。
    let _ = control.send(Control::Shutdown);
    drop(control);
    let _ = control_thread.join();
    0
}
