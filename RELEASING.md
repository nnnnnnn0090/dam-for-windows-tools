<!--
Project: DAM for Windows Tools
File: RELEASING.md
# Copyright (c) 2026 nnnnnnn0090. All rights reserved.
# Author: nnnnnnn0090
SPDX-License-Identifier: GPL-3.0-or-later
Created: 2026-08-22
-->

# リリース手順

## 前提

- Windows 10/11 x64
- Flutter 3.47.1 / Dart 3.13.1
- 有効なライセンスを持つVisual Studio 2022/2026の「C++によるデスクトップ開発」
- Git
- 初回ビルド時のインターネット接続
- gitの作業ツリーがクリーンで、リリース対象がコミット済みであること

`tool/cache/`はリポジトリへ含めません。新規clone後に`tool/build_release.ps1`を実行すると、Node.js 24.19.0、FFmpeg 9.0.1 Gyan full build、FFmpegとFridaの固定ソースを`tool/source_inputs.json`のHTTPS URLから自動取得します。全ファイルは同マニフェストのSHA-256と一致した場合だけ使用し、2回目以降は検証済みキャッシュを再利用します。既存キャッシュのハッシュが一致しない場合は上書きせず停止します。FFmpegは自前でビルドしません。

実行に必要なMicrosoft Visual C++ Runtimeは、ビルドに使用するVisual Studioの公式`VC\Redist`から必要なx64 DLLだけを無改変でアプリローカル収録します。ビルドはMicrosoft署名、ファイルバージョン、コピー前後のハッシュ、PE依存の閉包を検証します。これらのDLLはMicrosoft署名を保持するため、プロジェクトの証明書では再署名しません。ビルド担当者は使用するVisual StudioのライセンスおよびREDIST一覧に基づく再配布権を持つ必要があります。

```powershell
git clone <repository-url>
cd dam-for-windows-tools
.\tool\build_release.ps1
```

依存アーカイブだけを先に取得・検証する場合は`.\tool\bootstrap_dependencies.ps1`を実行します。

## 署名付きビルド

信頼されたコード署名証明書をWindows証明書ストアへ登録し、環境変数`DAM_TOOLS_SIGN_CERT_THUMBPRINT`へ空白を除いたthumbprintを設定します。必要に応じて`DAM_TOOLS_TIMESTAMP_URL`でRFC 3161タイムスタンプURLを指定します。

```powershell
.\tool\build_release.ps1 -RequireSignature
```

ビルド処理は一時ステージを自動検証してから、`dist/`へ次の4ファイルだけを生成します。

- `DAMforWindowsTools-1.1.0-win-x64.zip`
- `DAMforWindowsTools-1.1.0-win-x64.zip.sha256`
- `DAMforWindowsTools-1.1.0-source.zip`
- `DAMforWindowsTools-1.1.0-source.zip.sha256`

実行ZIPには実行時ファイル、利用案内、ライセンス、完全性情報だけを含めます。対応ソースと開発者向け文書はソースZIPへ分離し、実行ZIPと同じリリースページで公開してください。展開済み実行フォルダは`dist/`へ残しません。

署名対象はアプリ本体、同梱FFmpeg、FlutterのDLL、Fridaのネイティブモジュールです。Node.jsとMicrosoft Visual C++ Runtimeは上流のMicrosoft署名を検証します。証明書を持たない開発ビルドでは`-RequireSignature`を省略できますが、そのZIPを正式版として公開しません。

## 公開時の確認

- ZIPをクリーンなWindows 10/11 x64へ展開して起動する
- 対応DAMのハッシュ検証、初回再生、キャッシュ再生、各設定、動画指定、採点、リモコンの検索・予約・演奏操作を確認する
- 終了後にパッチ復元とセッション削除を確認する
- `SHA256SUMS.txt`を検証する
- ZIP自体のSHA-256をリリースページへ掲載する
- 実行ZIPと対応ソースZIPを必ず同じリリースで公開する
- GitHubのPrivate vulnerability reportingを有効にする
- リリースのソースタグとバイナリを同じコミットから生成する

`BUILD_INFO.json`にはソースコミット、固定ランタイム、対象DAM、署名有無を記録します。`SHA256SUMS.txt`はZIP内ファイルの破損検知用です。配布元の真正性は、コード署名、署名されたタグ、公開ページ上のZIPハッシュを組み合わせて確認します。
