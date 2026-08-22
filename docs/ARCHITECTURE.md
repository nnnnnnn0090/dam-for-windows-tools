<!--
Project: DAM for Windows Tools
File: ARCHITECTURE.md
Copyright (c) 2026 nnnnnnn0090. All rights reserved.
Author: nnnnnnn0090
SPDX-License-Identifier: GPL-3.0-or-later
Created: 2026-08-23
-->

# アーキテクチャ

本プロジェクトは、Flutterアプリ、ローカルHTTPサーバー、Node.jsヘルパー、Frida Agentを明確に分離しています。依存方向は、表示層からアプリケーション層、ドメイン層・インフラストラクチャ層へ向かう一方向です。

```text
Flutter UI
  └─ AppController
      └─ AppRuntime
          ├─ 永続化・OS連携
          ├─ 動画/HLSサーバー
          ├─ スマホリモコンサーバー
          └─ JSON Lines ─ Node.js helper ─ Frida Agent ─ DAM
```

## ディレクトリ

- `lib/domain/`: 設定、曲、再生、採点、リモコンの値と変換。Flutter UIやファイルシステムへ依存しません。
- `lib/application/`: ユースケース、状態管理、実行時コンポーネントのライフサイクルを担当します。
- `lib/infrastructure/`: 永続化、Windows連携、HTTP/HLS、Node.jsプロセスとの通信を担当します。
- `lib/presentation/`: Flutterの画面と部品だけを配置します。
- `assets/remote/`: スマホリモコンのHTML、CSS、JavaScriptです。実行時に単一ページへ組み立てます。
- `sidecar/`: Node.js側の接続、コマンド振り分け、Fridaセッション管理です。
- `sidecar/agent/`: 共有スコープを保ったまま機能順に分割したFrida Agentです。`agent_source.js`に定義した順序で連結します。
- `tool/`: 固定依存物の取得、ビルド、署名、配布検証を行います。

## 守るべき境界

- UIからNode.js、HTTPサーバー、ファイルを直接操作せず、`AppController`を通します。
- 永続化する履歴は公開動画ID、アーティスト名、曲名だけです。上流URL、セッショントークン、再生状態は保存しません。
- Fridaとの通信は相関ID付きJSON Linesに限定し、要求の完了管理は`RemoteRequestBroker`へ集約します。
- DAMの対象バージョン、SHA-256、RVA、期待バイト列は`sidecar/supported-dam.json`を唯一の定義元とします。
- Frida Agentの分割順序と実ファイル一覧はテストで一致を確認し、連結後の構文もビルド前に検証します。
- 配布ZIPは実行に必要なファイルだけを収録し、開発文書と対応ソースは別のソースZIPへ分離します。

## 起動と終了

1. Windowsの名前付きMutexで単一起動を確認します。
2. EXE横のデータ領域を初期化し、前回のセッション一時データを削除します。
3. 動画/HLSサーバー、Node.jsヘルパー、スマホリモコンサーバーの順に起動します。
4. DAMへ接続し、DAMが未起動なら自動接続を待機します。
5. 終了時はNode.js/Frida、FFmpeg、HTTPサーバーを停止し、パッチを復元してセッションデータを削除します。

## 検証

`flutter analyze`、Flutter単体試験、Node.js構文検査・単体試験、Windows releaseビルドを通した後、`tool/verify_release.ps1`が配布物の内容、ハッシュ、依存物、FFmpegのHLS動作、Fridaの読込を検証します。
