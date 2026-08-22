<!--
Project: DAM for Windows Tools
File: THIRD_PARTY_NOTICES.md
Copyright (c) 2026 nnnnnnn0090. All rights reserved.
Author: nnnnnnn0090
SPDX-License-Identifier: GPL-3.0-or-later
Created: 2026-08-22
-->

# Third-party notices

DAM for Windows Tools本体とは別に、配布フォルダは次の第三者ソフトウェアを含みます。各ライセンス本文は `LICENSES/`、Node依存パッケージのライセンスは `LICENSES/npm/`、Flutter/Dartパッケージの通知は `data/flutter_assets/NOTICES.Z` に収録されます。

DAM for Windows Toolsの自作部分はCopyright (c) 2026 nnnnnnn0090、`GPL-3.0-or-later`です。

| Component | Pinned version | License / notice |
|---|---:|---|
| Flutter | 3.47.1 | Flutter/Dartおよび各パッケージの通知は同梱の `NOTICES.Z` |
| QRCode for JavaScript algorithm | 2009 implementation | MIT; Flutter内のQR生成処理へ移植 |
| Node.js | 24.19.0 | Node.js license and bundled third-party notices |
| Frida Node bindings | 17.17.0 | LGPL-2.0 with WxWindows-exception-3.1 |
| FFmpeg | 9.0.1 Gyan full build | GPL-3.0; 固定配布物、構成、内蔵ライブラリ一覧は `LICENSES/FFmpeg-Gyan-README.txt`、実行時構成は `LICENSES/FFmpeg-Gyan-build.txt` |
| Microsoft Visual C++ Runtime | ビルド環境の署名済みv14 x64ランタイム | Microsoft Software License TermsおよびVisual Studio REDIST一覧; 無改変のアプリローカル配布 |

FFmpegはGyanの通常フル配布版から`ffmpeg.exe`だけを無改変で収録します。配布アーカイブは9.0.1タグへ固定し、アーカイブと実行ファイルのSHA-256を検証します。対応するFFmpegソース、DAM for Windows Toolsのソース、Frida、Frida Node、Frida Core、Frida Gumのソースは、実行ZIPと同時に公開する`DAMforWindowsTools-1.1.0-source.zip`へ分離しています。取得元と入力SHA-256はソースZIP内の`source_inputs.json`に記録します。

このファイルは各上流ライセンスの代替ではありません。再配布時は`LICENSES/`、`THIRD_PARTY_NOTICES.md`、`SHA256SUMS.txt`を削除せず、対応するソースZIPも同じ場所から取得できる状態にしてください。

Microsoft Visual C++ Runtimeは、有効なライセンスを持つVisual Studioの`VC\Redist`から、実行に必要なファイルだけを無改変で収録します。Microsoftの署名を保持し、当プロジェクトの証明書では再署名しません。詳細は`LICENSES/Microsoft-Visual-Cpp-Runtime.txt`を参照してください。
