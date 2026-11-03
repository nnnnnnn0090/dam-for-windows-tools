import 'package:flutter/services.dart';

import '../app_config.dart';

/// Windows runner（`windows/runner/flutter_window.cpp`）との連携です。
///
/// プロセス起動・URLを開く・ファイル選択はrunner側で行います。runnerは自身を
/// ジョブオブジェクトに入れているため、通常の子プロセスはアプリ終了時に必ず
/// 終了します。更新プログラムだけはジョブ外で起動する必要があり、ここを使います。
class NativeBridge {
  NativeBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(AppConfig.lifecycleChannel);

  final MethodChannel _channel;

  /// ウィンドウを閉じる要求（×ボタン・ログオフ）を受け取ります。
  /// [onClose] が完了すると、runnerへ閉じてよいことを伝えます。
  void listen({required Future<void> Function() onClose}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'closeRequested') return;
      try {
        await onClose();
      } finally {
        await _channel.invokeMethod<void>('closeReady');
      }
    });
  }

  /// 動画ファイルを選びます。キャンセルなら `null` です。
  Future<String?> pickVideoFile(List<String> extensions) =>
      _channel.invokeMethod<String>('pickVideoFile', <String, Object>{
        'extensions': extensions,
      });

  /// MP4の保存先を選びます。キャンセルなら `null` です。
  Future<String?> pickSaveFile(String fileName) =>
      _channel.invokeMethod<String>('pickSaveFile', <String, Object>{
        'fileName': fileName,
      });

  /// ファイルをエクスプローラーで選択した状態で表示します。
  Future<void> revealFile(String path) =>
      _channel.invokeMethod<void>('revealFile', <String, Object>{'path': path});

  /// 既定のブラウザでURLを開きます。
  Future<void> openUrl(String url) =>
      _channel.invokeMethod<void>('openUrl', <String, Object>{'url': url});

  /// ジョブオブジェクトの外でプロセスを起動します（更新プログラム用）。
  Future<void> launchDetached(String executable, List<String> arguments) =>
      _channel.invokeMethod<void>('launchDetached', <String, Object>{
        'executable': executable,
        'arguments': arguments,
      });
}
