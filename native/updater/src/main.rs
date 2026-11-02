// 自動更新の適用だけを行う常駐しない補助EXEです。コンソール窓を出さないためGUIサブシステムでビルドします。
#![windows_subsystem = "windows"]

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    ExitCode::from(updater::run_cli(&args))
}
