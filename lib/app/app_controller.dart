import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_config.dart';
import '../domain/settings.dart';
import '../domain/tracks.dart';
import '../domain/values.dart';
import '../infra/helper/dam_link.dart';
import '../infra/helper/helper_process.dart';
import '../infra/json_store.dart';
import '../infra/media/ffmpeg_progress.dart';
import '../infra/media/media_server.dart';
import '../infra/media/original_exporter.dart';
import '../infra/native_bridge.dart';
import '../infra/paths.dart';
import '../infra/remote/remote_server.dart';
import '../infra/stores.dart';
import '../infra/update_service.dart';
import 'states.dart';

/// アプリ全体の起動・終了と、各サービス間のイベントの受け渡しを担当します。
///
/// 画面は機能別の状態（[log]・[connection]・[history]・[scoring]・[update]・
/// [settings]）を個別に購読し、ここを直接は監視しません。
class AppController {
  AppController({AppPaths? paths, NativeBridge? bridge})
    : paths = paths ?? AppPaths.resolve(),
      bridge = bridge ?? NativeBridge();

  final AppPaths paths;
  final NativeBridge bridge;

  final LogState log = LogState();
  final ConnectionState connection = ConnectionState();
  final HistoryState history = HistoryState();
  final ScoringState scoring = ScoringState();
  final UpdateState update = UpdateState();

  /// 取り込み・変換・書き出しなど、裏で動いている作業の進み具合です。
  final TaskState tasks = TaskState();
  final ValueNotifier<AppSettings> settings = ValueNotifier<AppSettings>(
    const AppSettings(),
  );

  /// 差し替え動画が登録済みの動画IDです。
  final ValueNotifier<Set<String>> manualVideos = ValueNotifier<Set<String>>(
    const <String>{},
  );

  /// 公式動画の書き出しを表示するかです。権利上の理由で通常は隠し、
  /// 「0」キーを10回続けて押したときだけ、その起動中に限り表示します。
  final ValueNotifier<bool> exportUnlocked = ValueNotifier<bool>(false);

  /// 公式動画を書き出せる動画IDです（今回の起動中にDAMが再生した曲）。
  final ValueNotifier<Set<String>> exportableVideos =
      ValueNotifier<Set<String>>(const <String>{});

  /// 公式動画を書き出し中の動画IDです。
  final ValueNotifier<Set<String>> exportingVideos = ValueNotifier<Set<String>>(
    const <String>{},
  );

  /// リモコンのURLです。サーバー未起動・LAN未接続なら `null` です。
  final ValueNotifier<String?> remoteUrl = ValueNotifier<String?>(null);

  /// 起動に失敗した場合の理由です。
  final ValueNotifier<String?> fatalError = ValueNotifier<String?>(null);

  late final SettingsStore _settingsStore = SettingsStore(paths.settingsFile);
  late final HistoryStore _historyStore = HistoryStore(paths.historyFile);
  late final ManualVideoStore _videoStore = ManualVideoStore(
    paths.videosDirectory,
  );
  late final UpdateService _updates = UpdateService(
    paths: paths,
    bridge: bridge,
  );
  late final OriginalExporter _exporter = OriginalExporter(
    ffmpeg: paths.ffmpegExecutable,
  );

  /// 書き出しに使う、曲ごとの最新の公式動画URLです（古いものから捨てます）。
  final Map<String, PlaybackDescriptor> _upstreams =
      <String, PlaybackDescriptor>{};
  static const int _maximumUpstreams = 300;
  MediaServer? _media;
  DamLink? _link;
  RemoteServer? _remote;

  final Completer<void> _ready = Completer<void>();
  Future<void>? _shutdown;
  Future<void> _historySave = Future<void>.value();

  bool get updatesSupported => _updates.supported;
  bool get isShuttingDown => _shutdown != null;

  /// 各サービスを起動します。個別の失敗は機能を縮退して続行し、ログへ残します。
  Future<void> initialize() async {
    try {
      await paths.prepare();
      settings.value = await _loadOr(
        _settingsStore.load(),
        const AppSettings(),
        '設定',
      );
      history.restore(
        await _loadOr(_historyStore.load(), const <TrackRecord>[], '再生履歴'),
      );
      final videos = await _videoStore.load();
      manualVideos.value = videos.keys.toSet();

      final media = MediaServer(
        port: AppConfig.mediaServerPort,
        hlsDirectory: paths.hlsDirectory,
        ffmpeg: paths.ffmpegExecutable,
        progressive: Platform.environment['DAM_TOOLS_PROGRESSIVE_HLS'] == '1',
        onStage: _markStage,
        onLog: log.add,
        onProgress: _onTranscodeProgress,
      )..setManualSources(videos);
      try {
        await media.start();
        _media = media;
      } on SocketException catch (error) {
        log.add(
          'ローカル配信サーバーを起動できません。127.0.0.1:${AppConfig.mediaServerPort} を使う他のアプリを終了してください: $error',
        );
      }

      final link = DamLink(
        commandResolver: () =>
            HelperCommand.resolve(paths.root, Platform.environment),
        environment: <String, String>{
          'NODE_NO_WARNINGS': '1',
          'DAM_TOOLS_MEDIA_ORIGIN':
              'http://${AppConfig.loopbackHost}:${AppConfig.mediaServerPort}',
          'DAM_TOOLS_APP_ROOT': paths.root,
          'DAM_TOOLS_APP_VERSION': AppConfig.productVersion,
        },
        onEvent: _handleLinkEvent,
        onPrepare: _prepareReplacement,
      );
      _link = link;
      await link.start(settings.value.toHelperConfig());

      final remote = RemoteServer(
        port: AppConfig.remoteServerPort,
        backend: link,
        loadPage: _loadRemotePage,
        onLog: log.add,
      );
      try {
        await remote.start(
          onAddressChanged: () => remoteUrl.value = remote.url,
        );
        _remote = remote;
        remoteUrl.value = remote.url;
      } on SocketException catch (error) {
        log.add(
          'リモコンを起動できません。${AppConfig.remoteServerPort}番ポートを使う他のアプリを終了してください: $error',
        );
      }

      log.add('${AppConfig.productName} ${AppConfig.productVersion} を起動しました');
      final failure = await _updates.takeLastFailure().catchError(
        (Object _) => null,
      );
      if (failure != null && failure.isNotEmpty) {
        log.add('前回の自動更新に失敗したため旧版のまま起動しました: $failure');
      }
      _ready.complete();
    } on Object catch (error, stackTrace) {
      fatalError.value = '$error';
      log.add('起動に失敗しました: $error\n$stackTrace');
      _ready.complete();
    }
  }

  Future<T> _loadOr<T>(Future<T> load, T fallback, String label) async {
    try {
      return await load;
    } on CorruptFileException catch (error) {
      log.add('$labelのファイルが壊れていたため初期状態で起動します（元ファイルは退避済み）: $error');
      return fallback;
    }
  }

  // ---- 設定・履歴・差し替え動画 ----

  /// 設定を変更します。起動処理中に変更しても失われません。
  Future<void> updateSettings(AppSettings next) async {
    if (next == settings.value) return;
    settings.value = next;
    _link?.updateConfig(next.toHelperConfig());
    try {
      await _settingsStore.save(next);
    } on Object catch (error) {
      log.add('設定を保存できません: $error');
    }
  }

  Future<void> clearHistory() async {
    history.clear();
    _saveHistory();
    log.add('再生履歴を消去しました');
  }

  void _saveHistory() {
    final snapshot = history.records;
    _historySave = _historySave
        .then((_) => _historyStore.save(snapshot))
        .catchError((Object error) => log.add('再生履歴を保存できません: $error'));
  }

  /// 動画を選んで差し替えに登録します。キャンセルなら何もしません。
  Future<void> chooseManualVideo(String videoId) async {
    await _ready.future;
    if (tasks.isRunning(TaskKind.import, videoId)) return;
    final picked = await bridge.pickVideoFile(ManualVideoStore.extensions);
    if (picked == null) return;
    await _media?.forget(videoId);
    tasks.update(TaskKind.import, videoId, fraction: 0);
    final started = DateTime.now();
    final File stored;
    try {
      stored = await _videoStore.import(
        videoId,
        File(picked),
        onProgress: (copied, total) => tasks.update(
          TaskKind.import,
          videoId,
          fraction: total > 0 ? copied / total : null,
          detail: '${_megabytes(copied)} / ${_megabytes(total)}',
        ),
      );
    } finally {
      tasks.end(TaskKind.import, videoId);
    }
    await _media?.setManualSource(videoId, stored);
    manualVideos.value = <String>{...manualVideos.value, videoId};
    final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
    log.add(
      '[$videoId] 差し替え動画を保存しました'
      '（${_megabytes(await stored.length())}・${seconds.toStringAsFixed(1)}秒）',
    );
  }

  /// 変換の進み具合を作業一覧へ反映します（`null` は変換の終了）。
  void _onTranscodeProgress(String videoId, MediaProgress? progress) {
    if (progress == null) {
      tasks.end(TaskKind.transcode, videoId);
      return;
    }
    tasks.update(
      TaskKind.transcode,
      videoId,
      fraction: progress.fraction,
      detail: progress.describe(),
    );
  }

  static String _megabytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';

  Future<void> clearManualVideo(String videoId) async {
    await _ready.future;
    try {
      await _media?.setManualSource(videoId, null);
      await _videoStore.remove(videoId);
      manualVideos.value = <String>{...manualVideos.value}..remove(videoId);
      log.add('[$videoId] 差し替え動画を解除しました');
    } on FileSystemException catch (error) {
      log.add('[$videoId] 差し替え動画を削除できません: $error');
    }
  }

  /// 公式動画をMP4で書き出します。保存先は利用者が選び、キャンセルなら `null` です。
  ///
  /// 公式動画のURLは再生のたびにDAMから届くため、今回の起動中に再生した曲だけが対象です。
  Future<String?> exportOriginalVideo(TrackRecord record) async {
    await _ready.future;
    if (!exportUnlocked.value) return null;
    final videoId = record.videoId;
    final descriptor = _upstreams[videoId];
    if (descriptor == null) {
      throw const ExportException(
        'この曲は今回の起動中にまだ再生されていません。DAMで一度再生してから書き出してください',
      );
    }
    if (exportingVideos.value.contains(videoId)) return null;
    final path = await bridge.pickSaveFile(exportFileName(record));
    if (path == null) return null;
    exportingVideos.value = <String>{...exportingVideos.value, videoId};
    tasks.update(TaskKind.export, videoId, fraction: 0);
    log.add('[$videoId] 公式動画を書き出しています: $path');
    try {
      await _exporter.export(
        descriptor.upstreamUrls,
        File(path),
        onProgress: (progress) => tasks.update(
          TaskKind.export,
          videoId,
          fraction: progress.fraction,
          detail: progress.describe(),
        ),
      );
      log.add('[$videoId] 公式動画を書き出しました: $path');
      return path;
    } on Object catch (error) {
      log.add('[$videoId] 公式動画を書き出せません: $error');
      rethrow;
    } finally {
      tasks.end(TaskKind.export, videoId);
      exportingVideos.value = <String>{...exportingVideos.value}
        ..remove(videoId);
    }
  }

  void unlockExport() {
    if (exportUnlocked.value) return;
    exportUnlocked.value = true;
    log.add('公式動画の書き出しを表示しました（この起動中のみ）');
  }

  /// 書き出したファイルをエクスプローラーで表示します。
  Future<void> revealFile(String path) async {
    try {
      await bridge.revealFile(path);
    } on PlatformException catch (error) {
      log.add('エクスプローラーを開けません: ${error.message}');
    }
  }

  void _rememberUpstream(PlaybackDescriptor descriptor) {
    final videoId = descriptor.videoId;
    if (videoId.isEmpty || descriptor.upstreamUrls.isEmpty) return;
    _upstreams.remove(videoId);
    _upstreams[videoId] = descriptor;
    while (_upstreams.length > _maximumUpstreams) {
      _upstreams.remove(_upstreams.keys.first);
    }
    exportableVideos.value = _upstreams.keys.toSet();
  }

  void resetScoring() => scoring.reset();

  Future<void> reconnect() async => _link?.reconnect();

  Future<void> openRemoteInBrowser() async {
    final url = remoteUrl.value;
    if (url == null) return;
    try {
      await bridge.openUrl(url);
    } on PlatformException catch (error) {
      log.add('ブラウザを開けません: ${error.message}');
    }
  }

  // ---- 自動更新 ----

  Future<void> checkForUpdates() async {
    if (!updatesSupported || update.busy) return;
    update.set(UpdatePhase.checking, '更新を確認中');
    try {
      final found = await _updates.check();
      if (found == null) {
        update.set(UpdatePhase.latest, '最新版です');
      } else {
        update.set(
          UpdatePhase.available,
          'v${found.version} に更新',
          update: found,
        );
      }
    } on Object catch (error) {
      update.set(UpdatePhase.failed, '更新を確認できませんでした');
      log.add('更新情報を確認できません: $error');
    }
  }

  /// 更新を取得してupdaterへ引き継ぎ、アプリを終了します。
  Future<void> installUpdate() async {
    final target = update.available;
    if (target == null || update.busy) return;
    update.set(UpdatePhase.downloading, 'v${target.version} をダウンロード中');
    try {
      await _updates.install(target, onProgress: update.progress);
      update.set(UpdatePhase.restarting, '更新して再起動します');
      await shutdown();
      exit(0);
    } on Object catch (error) {
      update.set(UpdatePhase.available, '更新に失敗しました');
      log.add('自動更新に失敗しました: $error');
    }
  }

  // ---- 終了 ----

  /// 全サービスを止めます。何度呼んでも1回だけ実行され、各段階は時間制限付きです。
  Future<void> shutdown() => _shutdown ??= _doShutdown();

  Future<void> _doShutdown() async {
    Future<void> step(String name, Future<void>? Function() action) async {
      try {
        await action()?.timeout(const Duration(seconds: 8));
      } on Object catch (error) {
        log.add('$nameの停止に失敗しました: $error');
      }
    }

    await step('リモコン', () => _remote?.stop());
    await step('DAM接続', () => _link?.stop()); // DAMへの変更を復元します。
    await step('公式動画の書き出し', _exporter.close);
    await step('ローカル配信', () => _media?.stop());
    await step('再生履歴の保存', () => _historySave);
    await step('一時データ', paths.disposeSession);
    _updates.close();
  }

  // ---- 接続ヘルパーからのイベント ----

  void _handleLinkEvent(LinkEvent event) {
    switch (event) {
      case LinkStatusChanged(:final state, :final detail):
        connection.update(state, detail);
        if (state != LinkState.attached) scoring.deactivate();
      case LinkLog(:final message):
        if (message.isNotEmpty) log.add(message);
      case LinkNotice(:final type, :final payload):
        _handleNotice(type, payload);
    }
  }

  void _handleNotice(String type, Map<String, Object?> payload) {
    switch (type) {
      case 'metadata':
        final raw = payload['candidates'];
        final candidates = <MetadataCandidate>[
          for (final item in raw is List ? raw : const <Object?>[])
            if (jsonObject(item) case final object?)
              MetadataCandidate.fromJson(object),
        ];
        if (history.acceptMetadata(candidates)) _saveHistory();
      case 'playback':
        final videoId = normalizeVideoAssetId(payload['videoId']);
        if (videoId.isEmpty) {
          log.add('再生を検知しましたが動画IDを確定できませんでした');
          return;
        }
        history.registerPlayback(videoId);
        _saveHistory();
        _rememberUpstream(PlaybackDescriptor.fromJson(payload));
        log.add('[$videoId] 再生を検知しました');
      case 'rewritten':
        final videoId = normalizeVideoAssetId(payload['videoId']);
        if (videoId.isNotEmpty) {
          _markStage(videoId, PlaybackStage.rewritten, 'プレイヤー引数を置換');
        }
      case 'patch-error':
        log.add(
          'パッチ検証エラー: ${sanitizeText(payload['message'], maximumLength: 500)}',
        );
      case 'scoring-start':
        scoring.begin();
        log.add('採点を開始しました');
      case 'scoring-technique':
        final technique = payload['technique'];
        final value = payload['value'];
        if (technique is num && value is num) {
          scoring.add(techniqueId: technique.toInt(), value: value.toInt());
        }
      case 'scoring-stop':
        if (scoring.active) log.add('採点を終了しました');
        scoring.deactivate();
      default:
        log.add('未処理のイベント: $type');
    }
  }

  Future<({bool accepted, String localUrl, String error})> _prepareReplacement(
    Map<String, Object?> request,
  ) async {
    final descriptor = PlaybackDescriptor.fromJson(request);
    final media = _media;
    if (media == null) {
      return (accepted: false, localUrl: '', error: 'ローカル配信サーバーが停止しています');
    }
    try {
      final url = media.register(
        descriptor,
        skipMs: settings.value.effectiveSkipMs,
      );
      return (accepted: true, localUrl: url, error: '');
    } on Object catch (error) {
      if (descriptor.videoId.isNotEmpty) {
        _markStage(
          descriptor.videoId,
          PlaybackStage.officialFallback,
          '登録できません: $error',
        );
      }
      return (accepted: false, localUrl: '', error: '$error');
    }
  }

  void _markStage(String videoId, PlaybackStage stage, String detail) {
    history.markStage(videoId, stage);
    log.add('[$videoId] ${stage.label}: $detail');
  }

  Future<String>? _remotePage;

  Future<String> _loadRemotePage() => _remotePage ??= () async {
    final parts = await Future.wait(<Future<String>>[
      for (final name in <String>[
        'index.html',
        'styles.css',
        'app.js',
        'icons.svg',
      ])
        rootBundle.loadString('assets/remote/$name'),
    ]);
    final page = parts[0]
        .replaceAll('{{REMOTE_STYLES}}', parts[1])
        .replaceAll('{{REMOTE_SCRIPT}}', parts[2])
        .replaceAll('{{REMOTE_ICONS}}', parts[3])
        .replaceAll('{{PRODUCT_NAME}}', AppConfig.productName)
        .replaceAll('{{PRODUCT_VERSION}}', AppConfig.productVersion)
        .replaceAll('{{REMOTE_NAME}}', AppConfig.remoteName);
    if (RegExp(r'\{\{[A-Z_]+\}\}').hasMatch(page)) {
      throw StateError('リモコン画面のテンプレート展開に失敗しました');
    }
    return page;
  }();
}
