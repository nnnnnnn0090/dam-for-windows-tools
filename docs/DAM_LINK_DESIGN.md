# DAM接続ヘルパー 設計書

Flutterアプリと、DAMへ接続する「接続ヘルパー」の境界を定義します。
v2のFlutterアプリはこの仕様だけに依存し、ヘルパーの中身は差し替え可能です。

- **現行の実装**: v1の Node.js ヘルパー（`sidecar/`）をそのまま使用します。
- **将来の置き換え候補**: Rust製 `dam-link.exe`（未実装。本書の「Rust版の実装方針」を参照）。

## 1. 構成

```text
Flutterアプリ ──(stdin/stdout: JSON Lines, UTF-8)── 接続ヘルパー ── DAM
      │                                                  │
      └─ 127.0.0.1:8765 メディアサーバー ◀──(置換後のHLS URL)─┘
```

- ヘルパーはアプリの子プロセスとして1つだけ動きます。
- ヘルパーが異常終了しても、アプリの画面は巻き込まれません。アプリは状態を `helper-exited` にし、再起動を試みます（4章）。
- runner が自プロセスを Windows のジョブオブジェクト（`KILL_ON_JOB_CLOSE`）に入れており、ヘルパーも自動で同じジョブに入ります。これにより、アプリが強制終了されても子プロセスが残りません。

## 2. 起動

### 実行ファイルの解決順

アプリのルートは、EXEのあるフォルダです。

1. `runtime\dam-link.exe` があれば、それを引数なしで起動します。
2. なければ `runtime\node.exe runtime\helper\main.js` を起動します（v1互換）。
3. どちらも無ければ（開発時）、`tool/cache/node/node.exe helper/main.js` を起動します。
4. `DAM_TOOLS_HELPER` 環境変数があれば、上記より優先します。値には `node <path>\main.js` などのコマンドラインを指定します。

`cmd.exe` 経由（`runInShell`）では起動しません。v1では、`kill` で `cmd.exe` だけが終了し、本体が残る不具合がありました。

### 作業ディレクトリ

ヘルパーのあるフォルダです。

### 環境変数

親プロセスの環境変数を引き継いだうえで、次を追加します。

| 名前 | 値 | 用途 |
|---|---|---|
| `NODE_NO_WARNINGS` | `1` | Node版のみ。警告をstderrへ出しません |
| `DAM_TOOLS_MEDIA_ORIGIN` | `http://127.0.0.1:<port>` | 動画URLの置換先です。ループバックのHTTPのみ許可します |
| `DAM_TOOLS_APP_ROOT` | アプリのルート（絶対パス） | 採点オーバーレイDLLとアイコンの探索に使います |
| `DAM_TOOLS_APP_VERSION` | `x.y.z` | オーバーレイDLL名 `dam_scoring_overlay_x_y_z.dll` の決定に使います |

## 3. プロトコル

### 共通

- 1行が1つのJSONオブジェクトで、改行は `\n` です。どちらの方向も `type` フィールドで種別を表します。
- 1行の上限は次の通りです。上限を超えた行は読み捨て、ログに残します。
  - アプリ → ヘルパー: 64 KiB
  - ヘルパー → アプリ: 4 MiB。アプリ側は、行を組み立てる途中で上限を判定します（v1は組み立て後に判定していました）。
- stderrは診断ログとしてのみ扱います。不正なUTF-8を含んでいてもエラーにしません（`allowMalformed`）。
- アプリは受信したイベントを、届いた順に1件ずつ処理します。v1は並行処理していました。

### アプリ → ヘルパー（コマンド）

| type | フィールド | 説明 |
|---|---|---|
| `config` | `disableModuleCheck`, `disableForegroundCheck`, `replaceVideoUrls`, `scoringOverlayEnabled`, `scoringShowZeroTechniques`（すべて bool） | 機能設定です。起動直後と変更時に送ります。未接続のときは保持され、接続時に反映されます |
| `prepareResult` | `requestId`, `accepted`, `localUrl?`, `error?` | `prepare` への応答です |
| `reconnect` | なし | 切断して再探索します |
| `shutdown` | なし | DAMに適用した変更を復元し、切断してから終了します |
| `remoteSearch` | `requestId`, `query`, `mode` | `mode` は `keyword`, `title`, `artist`, `ranking`, `new`, `favorites`, `history` のいずれかです |
| `remoteDetail` | `requestId`, `token` | |
| `remoteReserve` | `requestId`, `token`, `mode`, `key`, `scoring`, `playType` | `mode` は `normal`, `cutIn`, `originalKey`。`key` は −7〜7。`playType` は `standard`, `guideVocal`, `artistVideo` |
| `remoteFavorite` | `requestId`, `token`, `action` | `action` は `add` または `remove` |
| `remoteState` | `requestId` | |
| `remoteControl` | `requestId`, `action` | `action` は `pause`, `resume`, `stop`, `restart`, `keyDown`, `keyUp`, `keyReset`, `scoringOn`, `scoringOff`, `confirmYes`, `confirmNo` のいずれかです |
| `remoteQueue` | `requestId` | |
| `remoteQueueAction` | `requestId`, `action`, `token` | `action` は `remove`, `moveUp`, `moveDown`。`token` は `^q_[cn]_[0-9]+$` に一致する文字列です |

`requestId` は、アプリが生成する `^[0-9a-f]{32}$` の文字列です。

### ヘルパー → アプリ（イベント）

| type | フィールド | 説明 |
|---|---|---|
| `status` | `state`, `detail` | 状態が変化したときだけ送ります。`state` は `ready`, `waiting`, `unsupported`, `attaching`, `attached`, `attach-error` のいずれかです |
| `log` | `message` | 診断ログです |
| `patch-error` | `message` | DAMへの変更の適用に失敗しました |
| `metadata` | `candidates: [{ids: [..], artist, title}]` | 曲情報の候補です |
| `playback` | `videoId`, `highUrl`, `lowUrl` | 再生を検知しました |
| `prepare` | `requestId`, `videoId`, `highUrl`, `lowUrl` | ローカルURLの登録要求です。1.9秒以内に応答がなければ、ヘルパーは公式URLを使います |
| `rewritten` | `videoId`, `highUrl`, `lowUrl` | URLを置き換えました |
| `scoring-start` / `scoring-stop` | なし | 採点が始まった、または終わりました |
| `scoring-technique` | `technique`, `value`, `timestamp` | 技法IDは0〜43。`value` は1以上、`timestamp` は0以上です |
| `remote-search-result` | `requestId`, `query`, `mode`, `total`, `rows`, `error?` | |
| `remote-detail-result` | `requestId`, `detail?`, `error?` | |
| `remote-reserve-result` | `requestId`, `accepted`, `message`, `videoId?`, `artist?`, `title?` | |
| `remote-favorite-result` | `requestId`, `accepted`, `favorite`, `message` | |
| `remote-state-result` / `remote-control-result` / `remote-queue-result` / `remote-queue-action-result` | `requestId`, `result?`, `error?` | |

要求には、必ず同じ `requestId` を持つ結果が1件だけ返ります。未接続や失敗の場合も `error` 付きで返ります。

## 4. ライフサイクル

1. アプリはメディアサーバーを起動してからヘルパーを起動し、直後に `config` を送ります。
2. ヘルパーは `ready` を通知し、DAMを750msごとに探索します。
   - 対応外のDAMのときは `unsupported` を通知し、何も適用しません。
   - 対応するDAMのときは、`attaching` を経て `attached` を通知します。
3. DAMが終了したら `waiting` に戻り、DAMが再起動すれば自動で再接続します。
4. **ヘルパーの終了と再起動（アプリ側）**
   - ヘルパーが予期せず終了したら、アプリは状態を `helper-exited` にし、待機中の要求をすべて失敗にします。
   - 再起動は、1秒・2秒・4秒…最大30秒の間隔で試みます。60秒間正常に動いたら、間隔を初期値に戻します。
   - 「再接続」ボタンを押したときも、ヘルパーが止まっていれば再起動します。v1では、アプリを再起動するまで復帰しませんでした。
5. **終了処理**
   - アプリは `shutdown` を送ってstdinを閉じ、最大5秒待ちます。終わらなければプロセスを強制終了します。
   - ヘルパーは、stdinのEOFを受け取ったときも `shutdown` と同じ処理をします。
   - ログオフやシャットダウン時（`WM_QUERYENDSESSION` / `WM_ENDSESSION`）も、同じ経路で終了します。

## 5. 要求の扱い（アプリ側）

- **同時実行の制御**
  - `remoteSearch`、`remoteDetail`、`remoteReserve`、`remoteFavorite` は、DAMの中で1件ずつしか処理できません。アプリが FIFO で直列化します。
  - `remoteState`、`remoteControl`、`remoteQueue`、`remoteQueueAction` は直列化しません。
- **タイムアウト**

  | 要求 | タイムアウト |
  |---|---|
  | `remoteSearch` | 17秒 |
  | `remoteDetail` / `remoteReserve` / `remoteFavorite` | 22秒 |
  | `remoteState` / `remoteControl` / `remoteQueue` / `remoteQueueAction` | 6秒 |

  - タイムアウトしても、直列化の枠はその要求の結果イベントが届くまで解放しません。上限は60秒です。
  - v1は枠をすぐ解放していたため、DAMの中では前の処理が続いたまま次の要求が送られ、予約の再試行で二重予約になる恐れがありました。
- **エラー**
  - ヘルパーの `error` 文字列は、アプリ内で `RemoteFailure`（`notConnected`, `busy`, `expired`, `timeout`, `rejected`, `internal`）へ分類します。
  - 分類規則は `lib/infra/helper/dam_link.dart` の `RemoteFailure.fromHelper` の1か所にまとめます。

## 6. Rust版 `dam-link.exe` の実装方針（未着手）

Node.js（約90MB）をなくすための置き換えです。プロトコルは3章と完全に同じにし、アプリ側は変更しません。

- **固定する依存物**: frida-core devkit 17.17.0。`tool/release.json` の `fridaCoreDevkit` に、SHA-256込みで固定済みです。`tool/bootstrap.ps1` が取得し、検証します。
- **ビルド**
  - devkit は静的CRT（/MT）でビルドされています。ワークスペースの `native/.cargo/config.toml` で `+crt-static` に揃えてあります。
  - libclang が必要な `frida` クレート（bindgen）は使いません。必要な関数だけを手書きのFFIで宣言します。
- **v1から引き継いで改善する点**
  - DAMプロセスの探索と実行ファイルのSHA-256計算は、Win32 API で行います。SHA-256はパス・サイズ・更新日時をキーにキャッシュします（v1は毎回Fridaで全プロセスを列挙していました）。
  - Agent RPC の応答待ちは、メッセージを受け取るコールバックの中で直接解決します。これにより、受信処理と応答待ちがお互いを待ち合うデッドロックを避けます。
  - DAMから切断されたら、待機中のRPCをすぐ失敗にします。
  - Agent の結合順は、ファイル名順（`agent/*.js`）とします。
- **配置**: `runtime\dam-link.exe`、`runtime\agent\*.js`、`runtime\agent\supported-dam.json`。

## 7. 試験

- アプリ側は、偽のヘルパーを使って試験します。偽のヘルパーは、`dart` で書いた、仕様どおりのイベントを返すスクリプトです。
  - 起動と終了
  - 異常終了からの再起動
  - 行長の上限
  - 結果イベントの順序
  - タイムアウト後も直列化の枠を保持すること
  - エラーの分類
- DAMとの結合確認は、実機で行います（README の確認手順を参照）。
