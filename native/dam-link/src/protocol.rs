//! アプリとの標準入出力（JSON Lines, UTF-8）です。`docs/DAM_LINK_DESIGN.md` の3章に従います。

use std::io::{self, BufRead, Write};
use std::sync::{Mutex, PoisonError};

use serde_json::{Value, json};

/// アプリ → ヘルパーの1行の上限です。
pub const MAX_COMMAND_LINE_BYTES: usize = 64 * 1024;

/// イベントの送信口です。複数のスレッドから呼ばれるため、1行単位で排他します。
pub struct Protocol {
    output: Mutex<Box<dyn Write + Send>>,
    last_status: Mutex<String>,
}

impl Protocol {
    pub fn new(output: Box<dyn Write + Send>) -> Self {
        Self {
            output: Mutex::new(output),
            last_status: Mutex::new(String::new()),
        }
    }

    pub fn stdout() -> Self {
        Self::new(Box::new(io::stdout()))
    }

    /// 1つの値を1行のJSONとして送ります。アプリが先に終了していても失敗にはしません。
    pub fn emit(&self, value: &Value) {
        let mut line = value.to_string();
        line.push('\n');
        let mut output = self.output.lock().unwrap_or_else(PoisonError::into_inner);
        let _ = output.write_all(line.as_bytes());
        let _ = output.flush();
    }

    pub fn log(&self, message: impl Into<String>) {
        self.emit(&json!({ "type": "log", "message": message.into() }));
    }

    /// 状態が変化したときだけ `status` を送ります。
    pub fn status(&self, state: &str, detail: impl Into<String>) {
        let detail = detail.into();
        let key = format!("{state}\n{detail}");
        {
            let mut last = self
                .last_status
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if *last == key {
                return;
            }
            *last = key;
        }
        self.emit(&json!({ "type": "status", "state": state, "detail": detail }));
    }
}

/// 入力の1行分です。
#[derive(Debug, PartialEq, Eq)]
pub enum Line {
    Text(String),
    /// 上限を超えたため、改行まで読み捨てた行です。
    TooLong,
}

/// 改行区切りで読み、行ごとに `on_line` を呼びます。EOFで戻ります。
///
/// 行を組み立てる途中で上限を判定するため、巨大な行でメモリを使い切りません。
pub fn read_lines(
    mut input: impl BufRead,
    maximum_bytes: usize,
    mut on_line: impl FnMut(Line),
) -> io::Result<()> {
    let mut line = Vec::new();
    let mut discarding = false;
    loop {
        let buffer = match input.fill_buf() {
            Ok(buffer) => buffer,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if buffer.is_empty() {
            if !discarding && !line.is_empty() {
                on_line(Line::Text(decode(&line)));
            }
            return Ok(());
        }
        let newline = buffer.iter().position(|&byte| byte == b'\n');
        let chunk = &buffer[..newline.unwrap_or(buffer.len())];
        if !discarding {
            if line.len() + chunk.len() > maximum_bytes {
                discarding = true;
                line.clear();
                on_line(Line::TooLong);
            } else {
                line.extend_from_slice(chunk);
            }
        }
        let consumed = newline.map_or(buffer.len(), |index| index + 1);
        input.consume(consumed);
        if newline.is_some() {
            if !discarding {
                on_line(Line::Text(decode(&line)));
            }
            discarding = false;
            line.clear();
        }
    }
}

fn decode(bytes: &[u8]) -> String {
    let text = String::from_utf8_lossy(bytes);
    text.strip_suffix('\r').unwrap_or(&text).to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn collect(input: &[u8], maximum: usize) -> Vec<Line> {
        let mut lines = Vec::new();
        // 小さな内部バッファで、行が複数回の読み取りにまたがる場合も試します。
        let reader = io::BufReader::with_capacity(7, input);
        read_lines(reader, maximum, |line| lines.push(line)).unwrap();
        lines
    }

    #[test]
    fn splits_lines_and_keeps_last_line_without_newline() {
        assert_eq!(
            collect(b"{\"a\":1}\r\n{\"b\":2}", 64),
            vec![
                Line::Text("{\"a\":1}".into()),
                Line::Text("{\"b\":2}".into())
            ]
        );
    }

    #[test]
    fn discards_oversized_line_and_resumes_after_newline() {
        let mut input = b"ok\n".to_vec();
        input.extend(std::iter::repeat_n(b'x', 100));
        input.extend(b"\nnext\n");
        assert_eq!(
            collect(&input, 16),
            vec![
                Line::Text("ok".into()),
                Line::TooLong,
                Line::Text("next".into())
            ]
        );
    }

    #[test]
    fn status_is_sent_only_when_changed() {
        let buffer = std::sync::Arc::new(Mutex::new(Vec::new()));
        let protocol = Protocol::new(Box::new(SharedBuffer(buffer.clone())));
        protocol.status("waiting", "a");
        protocol.status("waiting", "a");
        protocol.status("waiting", "b");
        let text = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert_eq!(text.lines().count(), 2);
    }

    struct SharedBuffer(std::sync::Arc<Mutex<Vec<u8>>>);

    impl Write for SharedBuffer {
        fn write(&mut self, data: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(data);
            Ok(data.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
}
