/// 製品名・保存先名・ポートなど、層をまたいで共有する固定値です。
///
/// 対象DAMのバージョン固有値は接続ヘルパー側の `supported-dam.json` が唯一の
/// 定義元で、アプリはそれに依存しません。
abstract final class AppConfig {
  static const productName = 'DAM for Windows Tools';
  static const productVersion = '2.0.0';
  static const executableName = 'DAMforWindowsTools.exe';
  static const updaterExecutableName = 'updater.exe';
  static const releaseArchiveRootName = 'DAMforWindowsTools';
  static const remoteName = 'DAM for Windows Remote';
  static const githubRepository = 'nnnnnnn0090/dam-for-windows-tools';
  static const legalSummary =
      '非公式・第一興商株式会社非公認のツールです。DAMおよび関連する名称は、'
      '各権利者に帰属します。正規に利用できる家庭内環境でのみ使用してください。';
  static const dataDirectoryName = 'DAMforWindowsToolsData';
  static const loopbackHost = '127.0.0.1';
  static const mediaServerPort = 8765;
  static const remoteServerPort = 8766;
  static const lifecycleChannel = 'dam-for-windows-tools/lifecycle';
}
