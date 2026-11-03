# Third-party notices

DAM for Windows Tools本体とは別に、配布フォルダは次の第三者ソフトウェアを含みます。各ライセンス本文は `LICENSES/` に、Flutter/Dartパッケージの通知は `data/flutter_assets/NOTICES.Z` に、Rustクレートのライセンスは各クレートの配布元に従います。

DAM for Windows Toolsの自作部分はCopyright (c) 2026 nnnnnnn0090、`GPL-3.0-or-later`です。

| Component | Pinned version | License / notice |
|---|---:|---|
| Flutter | 3.47.1 | Flutter/Dartおよび各パッケージの通知は同梱の `NOTICES.Z` |
| QRCode for JavaScript algorithm | 2009 implementation | MIT; Flutter内のQR生成処理へ移植 |
| Lucide Icons | 1.33.0 | ISC（一部Feather由来アイコンはMIT）; Webリモコンへ必要なSVGシンボルだけを同梱 |
| Frida Core (frida-core devkit) | 17.17.0 | LGPL-2.0 with WxWindows-exception-3.1; 無改変で `runtime/dam-link.exe` へ静的リンク（`LICENSES/FRIDA_SOURCE.txt`） |
| FFmpeg | 9.0.1 Gyan full build | GPL-3.0 (`LICENSES/FFmpeg-GPL-3.0.txt`); 構成は `LICENSES/FFmpeg-build-README.txt` |
| Rust standard library and crates | `native/Cargo.lock` | MIT / Apache-2.0 など。`updater.exe`・`runtime/dam-link.exe`・採点描画DLLへ静的リンク |
| Microsoft Visual C++ Runtime | ビルド環境の署名済みv14 x64ランタイム | Microsoft Software License TermsおよびVisual Studio REDIST一覧; 無改変のアプリローカル配布 |

FFmpegはGyanの通常フル配布版から `ffmpeg.exe` だけを無改変で収録します。アーカイブと実行ファイルのSHA-256は `tool/release.json` に固定しています。対応するFFmpegソース、DAM for Windows Toolsのソース、Frida、Frida Core、Frida Gumのソースは、実行ZIPと同時に公開する `DAMforWindowsTools-<版>-source.zip` に分けています。

このファイルは各上流ライセンスの代わりにはなりません。再配布するときは `LICENSES/`、`THIRD_PARTY_NOTICES.md`、`SHA256SUMS.txt` を削除しないでください。また、対応するソースZIPも同じ場所から取得できる状態にしてください。

Microsoft Visual C++ Runtimeは、有効なライセンスを持つVisual Studioの `VC\Redist` から、実行に必要なファイルだけを無改変で収録します。Microsoftの署名を保持し、当プロジェクトの証明書では再署名しません。
