//! アプリのコマンドを、接続中Agentの対応RPCへ振り分けます。
//!
//! 要求には、未接続や失敗の場合も含めて、同じ `requestId` の結果を必ず1件返します。

use std::time::Duration;

use serde_json::{Value, json};

use crate::link::{Link, require};
use crate::protocol::Protocol;

/// Agentが要求を受け付けるまでの上限です。結果そのものは後からイベントで届きます。
const START_TIMEOUT: Duration = Duration::from_secs(30);
/// 状態取得や演奏操作など、すぐに結果を返すRPCの上限です。
const COMMAND_TIMEOUT: Duration = Duration::from_secs(10);

/// アプリの要求のうち、Agentへ転送するものです。
pub fn is_remote_request(kind: &str) -> bool {
    matches!(
        kind,
        "remoteSearch"
            | "remoteDetail"
            | "remoteReserve"
            | "remoteFavorite"
            | "remoteState"
            | "remoteControl"
            | "remoteQueue"
            | "remoteQueueAction"
    )
}

fn text(command: &Value, name: &str) -> String {
    match &command[name] {
        Value::String(value) => value.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// 要求を1件処理します。DAMの応答を待つため、呼び出し元は専用のスレッドで呼びます。
pub fn handle_remote_request(link: &Link, protocol: &Protocol, command: &Value) {
    let kind = command["type"].as_str().unwrap_or("");
    let request_id = text(command, "requestId");
    let attachment = require(link.attachment());
    match kind {
        "remoteSearch" => {
            let query = text(command, "query");
            let mode = match text(command, "mode") {
                mode if mode.is_empty() => "keyword".to_owned(),
                mode => mode,
            };
            let started = attachment.and_then(|a| {
                a.call(
                    "remoteSearch",
                    json!([request_id, query, mode]),
                    START_TIMEOUT,
                )
            });
            if let Err(error) = started {
                protocol.emit(&json!({
                    "type": "remote-search-result",
                    "requestId": request_id,
                    "query": query,
                    "mode": mode,
                    "total": 0,
                    "rows": [],
                    "error": error,
                }));
            }
        }
        "remoteDetail" => {
            let started = attachment.and_then(|a| {
                a.call(
                    "remoteDetail",
                    json!([request_id, text(command, "token")]),
                    START_TIMEOUT,
                )
            });
            if let Err(error) = started {
                protocol.emit(&json!({
                    "type": "remote-detail-result",
                    "requestId": request_id,
                    "error": error,
                }));
            }
        }
        "remoteReserve" => {
            let mode = match text(command, "mode") {
                mode if mode.is_empty() => "normal".to_owned(),
                mode => mode,
            };
            let play_type = match text(command, "playType") {
                play_type if play_type.is_empty() => "standard".to_owned(),
                play_type => play_type,
            };
            let key = match &command["key"] {
                Value::Number(number) => Value::Number(number.clone()),
                _ => json!(0),
            };
            let options = json!({
                "mode": mode,
                "key": key,
                "scoring": command["scoring"] == Value::Bool(true),
                "playType": play_type,
            });
            let started = attachment.and_then(|a| {
                a.call(
                    "remoteReserve",
                    json!([request_id, text(command, "token"), options]),
                    START_TIMEOUT,
                )
            });
            if let Err(error) = started {
                protocol.emit(&json!({
                    "type": "remote-reserve-result",
                    "requestId": request_id,
                    "accepted": false,
                    "message": error,
                }));
            }
        }
        "remoteFavorite" => {
            let action = if command["action"] == "remove" {
                "remove"
            } else {
                "add"
            };
            let started = attachment.and_then(|a| {
                a.call(
                    "remoteFavorite",
                    json!([request_id, text(command, "token"), action]),
                    START_TIMEOUT,
                )
            });
            if let Err(error) = started {
                protocol.emit(&json!({
                    "type": "remote-favorite-result",
                    "requestId": request_id,
                    "accepted": false,
                    "favorite": action != "remove",
                    "message": error,
                }));
            }
        }
        _ => {
            let (result_type, method, arguments) = match kind {
                "remoteState" => ("remote-state-result", "remoteState", json!([])),
                "remoteControl" => (
                    "remote-control-result",
                    "remoteControl",
                    json!([text(command, "action")]),
                ),
                "remoteQueue" => ("remote-queue-result", "remoteQueue", json!([])),
                "remoteQueueAction" => (
                    "remote-queue-action-result",
                    "remoteQueueAction",
                    json!([text(command, "action"), text(command, "token")]),
                ),
                _ => return,
            };
            let event = match attachment.and_then(|a| a.call(method, arguments, COMMAND_TIMEOUT)) {
                Ok(result) => {
                    json!({ "type": result_type, "requestId": request_id, "result": result })
                }
                Err(error) => {
                    json!({ "type": result_type, "requestId": request_id, "error": error })
                }
            };
            protocol.emit(&event);
        }
    }
}
