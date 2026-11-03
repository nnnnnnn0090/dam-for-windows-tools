# アーキテクチャ

```text
DAMforWindowsTools.exe (Flutter / Dart)
 ├─ runner (C++)          単一起動・ジョブオブジェクト・終了時の受け渡し・ファイル選択
 ├─ AppController         起動/終了の順序と、サービス間のイベントの受け渡し
 │   ├─ 状態              Log / Connection / History / Scoring / Update / Settings
 │   ├─ Stores            settings.json / history.json / videos/
 │   ├─ MediaServer       127.0.0.1:8765  HLS中継・FFmpeg変換
 │   ├─ RemoteServer      0.0.0.0:8766    スマホリモコン
 │   ├─ UpdateService     GitHub Releases → updater.exe
 │   └─ DamLink ── JSON Lines(stdio) ── 接続ヘルパー (runtime/dam-link.exe, Rust + Frida) ── DAM
 │                                                         └─ dam_scoring_overlay_x_y_z.dll (Rust, DAM内で描画)
 └─ updater.exe (Rust)    検証・置き換え・ロールバック
```

## ディレクトリ

| パス | 内容 |
|---|---|
| `lib/domain/` | 値と変換。Flutter・ファイル・通信に依存しません |
| `lib/infra/` | 保存、HTTPサーバー、ヘルパー通信、更新、runner連携 |
| `lib/app/` | `AppController` と機能別の状態（`ChangeNotifier`） |
| `lib/ui/` | 画面。状態を購読し、操作は `AppController` を通します |
| `assets/remote/` | スマホリモコンの画面（単一HTMLへ組み立てて配信） |
| `helper/` | DAMの中で動くAgent（`agent/*.js`）と対応DAMの定義。Node.js版の接続ヘルパー（開発用）。境界は [DAM_LINK_DESIGN.md](DAM_LINK_DESIGN.md) |
| `native/` | Rust: `dam-link`（配布版の接続ヘルパー）、`scoring-overlay`（DAM内の採点グリッド描画DLL）、`updater` |
| `windows/runner/` | Flutterのrunner。単一起動・ジョブ・終了処理・ネイティブ操作のチャネル |
| `tool/` | 依存物の取得、配布ビルド、配布物検証 |

## 守っている約束

- **データを失わない**: JSONはファイルごとに書き込みを直列化し、一意な一時ファイルから置き換えます。読めないファイルは複製を残してから初期化し、複製できなければ上書きしません。
- **子プロセスを残さない**: runnerが自プロセスをジョブオブジェクト（`KILL_ON_JOB_CLOSE`）に入れるため、アプリが異常終了しても接続ヘルパーとFFmpegは終了します。更新プログラムだけはジョブ外で起動します。
- **必ず閉じられる**: ×ボタン・ログオフは停止処理（DAMへの変更の復元を含む）を待ってから閉じます。停止処理が止まっても20秒（ログオフ時は10秒）で閉じます。
- **DAMの中で同時に1件**: 検索・詳細・予約・お気に入りは直列化し、タイムアウト後も結果が届くまで次を送りません（二重予約の防止）。
- **LANからの操作を限定**: リモコンは送信元IP（プライベートのみ）→回数制限→同時数→Host→Origin→形式→サイズの順に検査します。URLには64桁のトークンが必要です。
- **更新は検証してから**: ZIP全体のSHA-256（`.sha256`）と、展開後の全ファイルのSHA-256（`SHA256SUMS.txt`）を確認し、失敗時は実際に置き換えたファイルだけを戻します。
- **配布物は列挙したものだけ**: `tool/build_release.ps1` が同梱物を明示的に集め、`tool/verify_release.ps1` が想定外のファイルを拒否します。

## 起動と終了

1. runner: 単一起動を確認（2つ目は既存ウィンドウを前面へ出して終了）し、ジョブオブジェクトへ参加。
2. `AppPaths.prepare`: 前回の一時領域を削除。
3. 設定・履歴・差し替え動画を読み込み。
4. MediaServer → DamLink（ヘルパー起動・設定送信）→ RemoteServer の順に起動。ポート競合などは該当機能だけ止めて続行します。
5. 終了: RemoteServer → DamLink（`shutdown` でDAMへの変更を復元）→ MediaServer → 履歴の保存完了待ち → 一時領域の削除。

## 動画の流れ

1. ヘルパーがDAMの再生要求を検知し `prepare` を送る（1.9秒以内に応答が必要）。
2. `MediaServer.register` はawaitを挟まずにジョブを登録し、ローカルURLを即答します。
3. DAMがマニフェストを要求すると、差し替え動画または遅延補正があればFFmpegで変換し、完成後にローカルHLSを返します。90秒を超えたらその回だけ公式HLSへ退避し、変換は続けます。
4. 差し替えも補正も無ければ、公式HLSを保存せずに中継します。

環境変数 `DAM_TOOLS_PROGRESSIVE_HLS=1` で、先頭2セグメントの完成時点で生成途中のプレイリストを返す方式を試せます（DAMでの動作は未確認のため既定は無効）。
