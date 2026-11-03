import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../../domain/remote.dart';
import '../../domain/values.dart';
import '../random_token.dart';
import '../remote/remote_server.dart';
import 'helper_process.dart';

/// 接続ヘルパーとDAMの接続状態です。
enum LinkState {
  starting,
  ready,
  waiting,
  attaching,
  attached,
  unsupported,
  attachError,
  helperExited,
  helperMissing;

  static LinkState fromWire(Object? value) => switch (value) {
    'ready' => ready,
    'waiting' => waiting,
    'attaching' => attaching,
    'attached' => attached,
    'unsupported' => unsupported,
    'attach-error' => attachError,
    _ => waiting,
  };

  bool get isError =>
      this == unsupported ||
      this == attachError ||
      this == helperExited ||
      this == helperMissing;
}

/// リモコン操作が失敗した理由です。HTTP応答の選択に使います。
enum RemoteFailureKind {
  notConnected,
  busy,
  expired,
  timeout,
  rejected,
  internal,
}

class RemoteFailure implements Exception {
  const RemoteFailure(this.kind, this.message);

  final RemoteFailureKind kind;
  final String message;

  /// ヘルパーが返した `error` 文字列を分類します。分類規則はここだけに置きます。
  factory RemoteFailure.fromHelper(String message) {
    final kind = switch (message) {
      _ when message.contains('接続されていません') => RemoteFailureKind.notConnected,
      _ when message.contains('another remote request is running') =>
        RemoteFailureKind.busy,
      _
          when message.contains('invalid or expired') ||
              message.contains('一覧を更新') =>
        RemoteFailureKind.expired,
      _ when message.contains('タイムアウト') => RemoteFailureKind.timeout,
      _ when message.contains('お待ちください') => RemoteFailureKind.notConnected,
      _ => RemoteFailureKind.rejected,
    };
    return RemoteFailure(kind, message);
  }

  @override
  String toString() => message;
}

/// ヘルパーから届く、要求への応答以外の通知です。
sealed class LinkEvent {
  const LinkEvent();
}

class LinkStatusChanged extends LinkEvent {
  const LinkStatusChanged(this.state, this.detail);
  final LinkState state;
  final String detail;
}

class LinkLog extends LinkEvent {
  const LinkLog(this.message);
  final String message;
}

/// それ以外の通知（metadata・playback・scoring-* など）は生のJSONで渡します。
class LinkNotice extends LinkEvent {
  const LinkNotice(this.type, this.payload);
  final String type;
  final Map<String, Object?> payload;
}

/// ローカルURL登録要求（`prepare`）への応答です。
typedef PrepareHandler =
    Future<({bool accepted, String localUrl, String error})> Function(
      Map<String, Object?> request,
    );

/// 接続ヘルパーの起動・再起動と、要求/応答の対応付けを担当します。
class DamLink implements RemoteBackend {
  DamLink({
    required this.commandResolver,
    required this.environment,
    required this.onEvent,
    required this.onPrepare,
    this.searchTimeout = const Duration(seconds: 17),
  });

  final HelperCommand? Function() commandResolver;
  final Map<String, String> environment;
  final void Function(LinkEvent event) onEvent;
  final PrepareHandler onPrepare;

  /// `remoteSearch` の呼び出し元へのタイムアウトです（試験で短くできます）。
  final Duration searchTimeout;

  static const Duration _operationTimeout = Duration(seconds: 22);
  static const Duration _commandTimeout = Duration(seconds: 6);
  static const Duration _slotHoldLimit = Duration(seconds: 60);
  static const Duration _initialBackoff = Duration(seconds: 1);
  static const Duration _maximumBackoff = Duration(seconds: 30);
  static const Duration _healthyRun = Duration(seconds: 60);

  HelperProcess? _process;
  Map<String, Object> _config = const <String, Object>{};
  bool _stopping = false;
  Duration _backoff = _initialBackoff;
  Timer? _restartTimer;
  LinkState _state = LinkState.starting;

  final Map<String, _Pending> _pending = <String, _Pending>{};
  final Queue<_Operation> _operations = Queue<_Operation>();
  bool _operationRunning = false;
  final LinkedHashMap<String, RemoteSongDetail> _detailCache =
      LinkedHashMap<String, RemoteSongDetail>();
  final Map<String, Future<RemoteSongDetail>> _detailRequests =
      <String, Future<RemoteSongDetail>>{};
  Future<RemoteControlState>? _stateRequest;

  LinkState get state => _state;
  bool get isAttached => _state == LinkState.attached;

  /// ヘルパーを起動します。失敗しても例外にせず、状態として通知して再試行します。
  Future<void> start(Map<String, Object> config) async {
    _config = config;
    _stopping = false;
    await _spawn();
  }

  /// 機能設定を送ります。未起動なら保持し、次の起動時に送ります。
  void updateConfig(Map<String, Object> config) {
    _config = config;
    _process?.send(<String, Object?>{'type': 'config', ...config});
  }

  /// DAMへ再接続します。ヘルパーが止まっていれば起動し直します。
  Future<void> reconnect() async {
    final process = _process;
    if (process != null && process.isRunning) {
      process.send(const <String, Object?>{'type': 'reconnect'});
      return;
    }
    _restartTimer?.cancel();
    _backoff = _initialBackoff;
    await _spawn();
  }

  /// ヘルパーへ終了を指示し、DAMへの変更が復元されるのを待ちます。
  Future<void> stop() async {
    _stopping = true;
    _restartTimer?.cancel();
    final process = _process;
    _process = null;
    _failAll(const RemoteFailure(RemoteFailureKind.notConnected, '終了処理中です'));
    await process?.stop();
  }

  // ---- リモコン操作 ----

  @override
  Future<List<RemoteSong>> search(String query, RemoteSearchMode mode) {
    final cleaned = sanitizeText(query, maximumLength: 1000);
    if (mode.needsQuery && cleaned.isEmpty || cleaned.length > 80) {
      return Future.error(const FormatException('検索語は1～80文字で入力してください'));
    }
    return _serial(
      'remoteSearch',
      <String, Object>{
        'query': mode.needsQuery ? cleaned : '',
        'mode': mode.wireName,
      },
      searchTimeout,
      (event) {
        final limit = mode == RemoteSearchMode.favorites ? 100 : 50;
        final rows = event['rows'];
        return <RemoteSong>[
          for (final raw in rows is List ? rows : const <Object?>[])
            if (jsonObject(raw) case final row?)
              if (RemoteSong.fromJson(row) case final song
                  when song.isDisplayable)
                song,
        ].take(limit).toList(growable: false);
      },
    );
  }

  @override
  Future<RemoteSongDetail> detail(String token) {
    final cached = _detailCache[token];
    if (cached != null) return Future.value(cached);
    final running = _detailRequests[token];
    if (running != null) return running;
    final request =
        _serial(
              'remoteDetail',
              <String, Object>{'token': token},
              _operationTimeout,
              (event) {
                final detail = jsonObject(event['detail']);
                if (detail == null) {
                  throw const RemoteFailure(
                    RemoteFailureKind.internal,
                    'DAMから不正な曲詳細を受信しました',
                  );
                }
                return RemoteSongDetail.fromJson(detail);
              },
            )
            .then((detail) {
              _detailCache[token] = detail;
              while (_detailCache.length > 400) {
                _detailCache.remove(_detailCache.keys.first);
              }
              return detail;
            })
            // `=> remove(...)` だと取り除いた Future（この要求自身）を返し、
            // whenComplete が自分の完了を待って永久に終わらなくなります。
            // 取り除いた値は呼び出し元が待っているので、ここでは待ちません。
            .whenComplete(() {
              unawaited(_detailRequests.remove(token));
            });
    _detailRequests[token] = request;
    return request;
  }

  @override
  Future<RemoteReservationResult> reserve(
    String token,
    RemoteReservationOptions options,
  ) => _serial(
    'remoteReserve',
    <String, Object>{
      'token': token,
      'mode': options.mode.name,
      'key': options.key.clamp(minimumKey, maximumKey),
      'scoring': options.scoring,
      'playType': options.playType.name,
    },
    _operationTimeout,
    RemoteReservationResult.fromJson,
  );

  @override
  Future<RemoteFavoriteResult> favorite(String token, {required bool add}) =>
      _serial(
        'remoteFavorite',
        <String, Object>{'token': token, 'action': add ? 'add' : 'remove'},
        _operationTimeout,
        RemoteFavoriteResult.fromJson,
      );

  /// 同時に複数来た状態取得は、実行中の1件にまとめます。
  @override
  Future<RemoteControlState> controlState() => _stateRequest ??= _command(
    'remoteState',
    const <String, Object>{},
    (result) {
      return RemoteControlState.fromJson(_resultObject(result));
    },
  ).whenComplete(() => _stateRequest = null);

  @override
  Future<RemoteControlState> control(RemoteControlAction action) => _command(
    'remoteControl',
    <String, Object>{'action': action.name},
    (result) => RemoteControlState.fromJson(_resultObject(result)),
  );

  @override
  Future<List<RemoteQueueEntry>> queue() =>
      _command('remoteQueue', const <String, Object>{}, _queueRows);

  @override
  Future<List<RemoteQueueEntry>> queueAction(
    RemoteQueueAction action,
    String token,
  ) => _command('remoteQueueAction', <String, Object>{
    'action': action.name,
    'token': token,
  }, _queueRows);

  // ---- 内部処理 ----

  Future<void> _spawn() async {
    if (_stopping) return;
    final command = commandResolver();
    if (command == null) {
      _setState(LinkState.helperMissing, '接続ヘルパーが見つかりません');
      return;
    }
    _setState(LinkState.starting, '接続ヘルパーを起動しています');
    final HelperProcess process;
    try {
      process = await HelperProcess.start(
        command: command,
        environment: environment,
        onEvent: _handleEvent,
        onLog: (message) => onEvent(LinkLog(message)),
      );
    } on ProcessException catch (error) {
      // 実行ファイルが無い場合は再試行しても直らないため、待機せず案内します。
      _setState(
        LinkState.helperMissing,
        '接続ヘルパーを起動できません（${command.executable}）',
      );
      onEvent(LinkLog('接続ヘルパーを起動できません: ${error.message}'));
      return;
    } on Object catch (error) {
      _setState(LinkState.helperExited, '接続ヘルパーを起動できません');
      onEvent(LinkLog('接続ヘルパーを起動できません: $error'));
      _scheduleRestart();
      return;
    }
    _process = process;
    process.send(<String, Object?>{'type': 'config', ..._config});
    final startedAt = DateTime.now();
    unawaited(
      process.exitCode.then((code) {
        if (!identical(_process, process)) return;
        _process = null;
        _failAll(
          const RemoteFailure(RemoteFailureKind.notConnected, '接続ヘルパーが終了しました'),
        );
        if (_stopping) return;
        if (DateTime.now().difference(startedAt) > _healthyRun) {
          _backoff = _initialBackoff;
        }
        _setState(LinkState.helperExited, '接続ヘルパーが終了しました (終了コード $code)');
        _scheduleRestart();
      }),
    );
  }

  void _scheduleRestart() {
    if (_stopping) return;
    final delay = _backoff;
    _backoff = _backoff * 2 > _maximumBackoff ? _maximumBackoff : _backoff * 2;
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () => unawaited(_spawn()));
  }

  void _setState(LinkState state, String detail) {
    _state = state;
    if (state != LinkState.attached) {
      _detailCache.clear();
    }
    onEvent(LinkStatusChanged(state, detail));
  }

  Future<void> _handleEvent(Map<String, Object?> event) async {
    final type = event['type'];
    if (type is! String) return;
    switch (type) {
      case 'status':
        _setState(
          LinkState.fromWire(event['state']),
          sanitizeText(event['detail'], maximumLength: 500),
        );
      case 'log':
        onEvent(LinkLog(sanitizeText(event['message'], maximumLength: 2000)));
      case 'prepare':
        await _answerPrepare(event);
      case _ when type.startsWith('remote-') && type.endsWith('-result'):
        _complete(event);
      default:
        onEvent(LinkNotice(type, event));
    }
  }

  Future<void> _answerPrepare(Map<String, Object?> event) async {
    final requestId = event['requestId'];
    if (requestId is! String || requestId.isEmpty) return;
    ({bool accepted, String localUrl, String error}) answer;
    try {
      answer = await onPrepare(event);
    } on Object catch (error) {
      answer = (accepted: false, localUrl: '', error: '$error');
    }
    _process?.send(<String, Object?>{
      'type': 'prepareResult',
      'requestId': requestId,
      'accepted': answer.accepted,
      'localUrl': answer.localUrl,
      'error': answer.error,
    });
  }

  void _complete(Map<String, Object?> event) {
    final pending = _pending.remove(event['requestId']);
    if (pending == null) return;
    final error = event['error'];
    if (error is String && error.trim().isNotEmpty) {
      pending.fail(RemoteFailure.fromHelper(error.trim()));
    } else {
      pending.succeed(event);
    }
  }

  /// DAMの中で1件ずつしか処理できない操作を直列化します。
  ///
  /// 呼び出し元へのタイムアウト後も、結果イベントが届くまで（最大60秒）枠を保持し、
  /// DAMの中で前の処理が続いているうちに次の要求を送らないようにします。
  /// まだ送っていない要求は、呼び出し元がタイムアウトした時点で取り消します
  /// （誰も待っていない要求を後から送り、DAMの混雑を長引かせないため）。
  Future<T> _serial<T>(
    String type,
    Map<String, Object> fields,
    Duration timeout,
    T Function(Map<String, Object?> event) decode,
  ) {
    final operation = _Operation(type, fields);
    _operations.add(operation);
    _pumpOperations();
    return operation.response.future
        .timeout(
          timeout,
          onTimeout: () {
            _operations.remove(operation);
            throw const RemoteFailure(
              RemoteFailureKind.timeout,
              'DAMの応答がタイムアウトしました',
            );
          },
        )
        .then(decode);
  }

  void _pumpOperations() {
    if (_operationRunning || _operations.isEmpty) return;
    final operation = _operations.removeFirst();
    _operationRunning = true;
    final pending = _send(operation.type, operation.fields);
    unawaited(
      pending.future
          .then(
            operation.response.complete,
            onError: operation.response.completeError,
          )
          .timeout(
            _slotHoldLimit,
            onTimeout: () =>
                _pending.removeWhere((_, v) => identical(v, pending)),
          )
          .whenComplete(() {
            _operationRunning = false;
            _pumpOperations();
          }),
    );
  }

  Future<T> _command<T>(
    String type,
    Map<String, Object> fields,
    T Function(Object? result) decode,
  ) {
    final pending = _send(type, fields);
    return pending.future
        .timeout(
          _commandTimeout,
          onTimeout: () {
            _pending.removeWhere((_, value) => identical(value, pending));
            throw const RemoteFailure(
              RemoteFailureKind.timeout,
              'DAMの応答がタイムアウトしました',
            );
          },
        )
        .then((event) => decode(event['result']));
  }

  _Pending _send(String type, Map<String, Object> fields) {
    final pending = _Pending();
    final process = _process;
    if (process == null || !process.isRunning || !isAttached) {
      pending.fail(
        const RemoteFailure(RemoteFailureKind.notConnected, 'DAMに接続されていません'),
      );
      return pending;
    }
    final requestId = randomHex(16);
    _pending[requestId] = pending;
    if (!process.send(<String, Object?>{
      'type': type,
      'requestId': requestId,
      ...fields,
    })) {
      _pending.remove(requestId);
      pending.fail(
        const RemoteFailure(RemoteFailureKind.notConnected, '接続ヘルパーが終了しています'),
      );
    }
    return pending;
  }

  void _failAll(RemoteFailure failure) {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final item in pending) {
      item.fail(failure);
    }
    while (_operations.isNotEmpty) {
      _operations.removeFirst().response.completeError(failure);
    }
    _detailCache.clear();
  }

  static Map<String, Object?> _resultObject(Object? result) =>
      jsonObject(result) ??
      (throw const RemoteFailure(
        RemoteFailureKind.internal,
        'DAMから不正な応答を受信しました',
      ));

  static List<RemoteQueueEntry> _queueRows(Object? result) =>
      <RemoteQueueEntry>[
        for (final raw in result is List ? result : const <Object?>[])
          if (jsonObject(raw) case final row?)
            if (RemoteQueueEntry.fromJson(row) case final entry
                when entry.token.isNotEmpty && entry.queueId > 0)
              entry,
      ].take(11).toList(growable: false);
}

class _Pending {
  final Completer<Map<String, Object?>> _completer =
      Completer<Map<String, Object?>>();

  Future<Map<String, Object?>> get future => _completer.future;

  void succeed(Map<String, Object?> event) {
    if (!_completer.isCompleted) _completer.complete(event);
  }

  void fail(Object error) {
    if (!_completer.isCompleted) _completer.completeError(error);
  }
}

class _Operation {
  _Operation(this.type, this.fields);

  final String type;
  final Map<String, Object> fields;
  final Completer<Map<String, Object?>> response =
      Completer<Map<String, Object?>>();
}
