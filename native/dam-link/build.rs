// frida-core devkit（tool/bootstrap.ps1 が取得・検証したもの）を静的リンクします。
// 置き場所は `FRIDA_CORE_DEVKIT` で上書きできます。既定は tool/cache/frida-core-devkit です。

use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-env-changed=FRIDA_CORE_DEVKIT");
    let devkit = std::env::var_os("FRIDA_CORE_DEVKIT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("..")
                .join("..")
                .join("tool")
                .join("cache")
                .join("frida-core-devkit")
        });
    let library = devkit.join("frida-core.lib");
    if !library.is_file() {
        panic!(
            "frida-core.lib が見つかりません: {}\n`tool/bootstrap.ps1` を実行してください",
            library.display()
        );
    }
    println!("cargo:rerun-if-changed={}", library.display());
    println!("cargo:rustc-link-search=native={}", devkit.display());
    println!("cargo:rustc-link-lib=static=frida-core");
    // frida-core.h の `#pragma comment(lib, ...)` のシステムライブラリと、USB監視が使う setupapi です。
    for name in [
        "advapi32", "crypt32", "dnsapi", "gdi32", "iphlpapi", "kernel32", "ole32", "psapi",
        "secur32", "setupapi", "shell32", "shlwapi", "user32", "winmm", "ws2_32",
    ] {
        println!("cargo:rustc-link-lib=dylib={name}");
    }
}
