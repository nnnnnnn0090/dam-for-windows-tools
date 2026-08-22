<!--
Project: DAM for Windows Tools
File: SECURITY.md
# Copyright (c) 2026 nnnnnnn0090. All rights reserved.
# Author: nnnnnnn0090
SPDX-License-Identifier: GPL-3.0-or-later
Created: 2026-08-22
-->

# セキュリティポリシー

## サポート対象

最新リリースだけをセキュリティ更新の対象とします。対応するDAM本体のバージョンとSHA-256はREADMEおよび`sidecar/supported-dam.json`に明記します。不一致の実行ファイルはサポート対象外です。

## 非公開での報告

公開リポジトリの「Security」からPrivate vulnerability reportingを使用してください。悪用手順、セッショントークン、個人情報、対象サービスの認証情報を公開Issueへ投稿しないでください。

報告には、影響、再現条件、対象バージョン、最小限の再現手順を含めてください。受領確認後、影響と修正方針を確認し、修正版の公開までは詳細の公開を控えてください。

## 想定する利用環境

- 書き込み可能な利用者フォルダへ展開する
- 正規に利用できる家庭内環境で使用する
- リモコンは信頼できるプライベートLANだけで使用する
- Windowsファイアウォールはプライベートネットワークだけを許可する
- リモコンのQRコードとURLを第三者へ共有しない

リモコンはHTTPであり、TLSを提供しません。公共Wi-Fi、来客用Wi-Fi、店舗、職場など第三者が参加できるネットワークはサポート対象外です。
