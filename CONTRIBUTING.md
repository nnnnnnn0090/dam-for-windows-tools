# コントリビューション

コードを変更する前に、[アーキテクチャ](docs/ARCHITECTURE.md)と[DAM接続ヘルパー設計書](docs/DAM_LINK_DESIGN.md)を確認してください。

Issueや変更を送る前に、最新コミットで再現することと、READMEに記載された対象DAMのバージョン・SHA-256を確認してください。認証情報、セッショントークン、個人情報、第三者の非公開コードや解析プロジェクトを投稿しないでください。脆弱性は `SECURITY.md` に従って非公開で報告してください。

## 開発環境

- Flutter 3.47.1（Dart 3.13.1）
- Visual Studio 2026 Build Tools（C++によるデスクトップ開発）
- Rust 1.99（`x86_64-pc-windows-msvc`）
- Windows PowerShell 5.1 以降

```powershell
./tool/bootstrap.ps1      # FFmpeg・Node.js・frida-core devkitを取得・検証し、helper/ の依存を入れる
flutter run -d windows    # リポジトリ直下で実行すると helper/（Node.js版）を接続ヘルパーとして使う
```

配布版と同じ Rust 製の接続ヘルパーで試すときは、ビルドしてから `DAM_TOOLS_HELPER` で指定します。

```powershell
cd native; cargo build --release -p dam-link; cd ..
$env:DAM_TOOLS_HELPER = "$PWD\native\target\release\dam-link.exe"; flutter run -d windows
```

## 確認

次がすべて通る必要があります（CIでも同じ内容を実行します）。

```powershell
dart format --output=none --set-exit-if-changed lib test
dart analyze --fatal-infos
flutter test
cd native; cargo fmt --check; cargo clippy --release --workspace --all-targets -- -D warnings; cargo test --release --workspace; cd ..
cd helper; ../tool/cache/node/node.exe check_agent_syntax.js; ../tool/cache/node/node.exe --test; cd ..
flutter build windows --release
```

## 方針

- 変更は小さく保ち、目的・確認方法・影響する機能を説明してください。
- 画面は状態を購読するだけにし、処理は `AppController` を通してください。
- 接続ヘルパーとアプリの間のプロトコルを変える場合は、先に `docs/DAM_LINK_DESIGN.md` を更新し、`helper/` と `native/dam-link/` の両方を合わせてください。
- PowerShellスクリプトはWindows PowerShell 5.1で読めるよう、BOM付きUTF-8で保存してください。
- 生成物、ビルドキャッシュ、DAM本体、動画、HLS、ログ、解析プロジェクトなど、ソースではないものはコミットしません。

提出者は、その変更を提出する権利を持ち、第三者の実装を無断で複製していないことを確認してください。提出された自作部分は、本プロジェクトと同じ `GPL-3.0-or-later` で提供されます。
