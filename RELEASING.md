# リリース手順

1. 版数を揃えます。`tool/release.json` の `releaseVersion`、`pubspec.yaml` の `version`（build-numberは1増やす）、`lib/app_config.dart` の `productVersion`、`native/Cargo.toml` の `version`。`CHANGELOG.md` に変更点を書きます。
2. コミットし、作業ツリーをクリーンにします。
3. 配布物を作ります。

   ```powershell
   ./tool/build_release.ps1
   ```

   版数・ツールチェーンの一致確認、依存物の検証、全試験、ビルド、同梱物の列挙、`tool/verify_release.ps1` による検証を行い、`dist/` に次を出力します。

   | ファイル | 内容 |
   |---|---|
   | `DAMforWindowsTools-<版>-win-x64.zip` | 配布物（ルートは `DAMforWindowsTools/`） |
   | `DAMforWindowsTools-<版>-win-x64.zip.sha256` | ZIPのSHA-256。**自動更新に必須** |
   | `DAMforWindowsTools-<版>-source.zip` | 本体ソースと、FFmpeg・Fridaの対応ソース |

4. GitHubでタグ `v<版>` のリリースを作り、上の3ファイルを添付します。`.sha256` が無いリリースは、2.x の自動更新の対象になりません。
5. 公開後、旧版から「更新」で新版へ更新できることを確認します。

## 自動更新の互換性

- 2.x の更新は、ZIPの `.sha256` と、ZIP内の `BUILD_INFO.json`（`releaseVersion`）・`SHA256SUMS.txt` を検証します。
- 1.x の更新スクリプトも同じZIP構造（ルート `DAMforWindowsTools/`、`DAMforWindowsTools.exe`、`BUILD_INFO.json`、`SHA256SUMS.txt`）を要求します。このため、1.x からも「更新」で 2.x へ移行できます。構造を変えるときは、この互換性を確認してください。

## コード署名（任意）

署名する場合は、`dist/stage` に集めた自作バイナリ（`DAMforWindowsTools.exe`、`updater.exe`、採点描画DLL）だけに署名します。その後で `SHA256SUMS.txt` を作り直してください。第三者のバイナリ（FFmpeg、Node.js、Frida、MSVCランタイム）は再署名しません。
