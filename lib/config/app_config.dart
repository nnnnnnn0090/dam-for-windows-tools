// Project: DAM for Windows Tools
// File: app_config.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

/// 製品名、保存先名、ポートなど、層をまたいで共有する固定値を集約します。
///
/// 対象DAMのバージョン固有値はSidecarマニフェスト側へ分離し、将来の対応版追加で
/// GUIや保存形式まで変更する必要がない構成にしています。
abstract final class AppConfig {
  static const productName = 'DAM for Windows Tools';
  static const remoteName = 'DAM for Windows Remote';
  static const legalSummary =
      '非公式・第一興商株式会社非公認のツールです。DAMおよび関連する名称は、'
      '各権利者に帰属します。正規に利用できる家庭内環境でのみ使用してください。';
  static const dataDirectoryName = 'DAMforWindowsToolsData';
  static const singletonMutexName = 'Local\\DAMforWindowsTools.Singleton';

  static const loopbackHost = '127.0.0.1';
  static const mediaServerPort = 8765;
  static const remoteServerPort = 8766;
  static const mediaServerOrigin = 'http://$loopbackHost:$mediaServerPort';
  static const remotePageAsset = 'assets/remote/index.html';
  static const remoteStyleAsset = 'assets/remote/styles.css';
  static const remoteScriptAsset = 'assets/remote/app.js';
  static const lifecycleChannel = 'dam-for-windows-tools/lifecycle';
}
