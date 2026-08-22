<!--
Project: DAM for Windows Tools
File: CONTRIBUTING.md
Copyright (c) 2026 nnnnnnn0090. All rights reserved.
Author: nnnnnnn0090
SPDX-License-Identifier: GPL-3.0-or-later
Created: 2026-08-22
-->

# コントリビューション

コードを変更する前に、[アーキテクチャ](docs/ARCHITECTURE.md)の責務境界と依存方向を確認してください。

Issueや変更を送る前に、最新コミットで再現することと、READMEに記載された対象DAMのバージョン・SHA-256を確認してください。認証情報、セッショントークン、個人情報、第三者の非公開コードや解析プロジェクトを投稿しないでください。脆弱性は`SECURITY.md`に従って非公開で報告してください。

変更は小さく保ち、目的、確認方法、影響する機能を説明してください。次の確認がすべて通る必要があります。

```powershell
npm ci --prefix sidecar
npm run check --prefix sidecar
npm test --prefix sidecar
npm audit --omit=dev --prefix sidecar
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

提出者は、その変更を提出する権利を持ち、第三者の実装を無断で複製していないことを確認してください。提出された自作部分は、本プロジェクトと同じ`GPL-3.0-or-later`で提供されます。生成物、ビルドキャッシュ、DAM本体、動画、HLS、ログ、AI作業ファイル、Ghidraプロジェクトなど、プログラム本体のソースではないものはコミットしません。

自作のテキストソースには、ファイル先頭へプロジェクト名、ファイル名、著作権者、作者、SPDXライセンス識別子、作成日を記載します。自動生成ファイルと上流ライセンス原文は改変せず、それぞれの生成元・上流表示を維持します。
