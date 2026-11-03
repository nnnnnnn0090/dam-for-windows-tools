// DAMへ接続する接続ヘルパーです。アプリの子プロセスとして、標準入出力のJSON Linesで通信します。

use std::process::ExitCode;

fn main() -> ExitCode {
    ExitCode::from(dam_link::run())
}
