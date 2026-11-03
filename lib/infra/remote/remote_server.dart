import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/remote.dart';
import '../../domain/values.dart';
import '../helper/dam_link.dart';
import '../random_token.dart';

/// リモコンAPIが呼び出す操作です。[DamLink] が実装します。
abstract interface class RemoteBackend {
  Future<List<RemoteSong>> search(String query, RemoteSearchMode mode);
  Future<RemoteSongDetail> detail(String token);
  Future<RemoteReservationResult> reserve(
    String token,
    RemoteReservationOptions options,
  );
  Future<RemoteFavoriteResult> favorite(String token, {required bool add});
  Future<RemoteControlState> controlState();
  Future<RemoteControlState> control(RemoteControlAction action);
  Future<List<RemoteQueueEntry>> queue();
  Future<List<RemoteQueueEntry>> queueAction(
    RemoteQueueAction action,
    String token,
  );
}

/// 家庭内LANのスマホへリモコン画面とAPIを提供するHTTPサーバーです。
///
/// URLは `http://<LAN IP>:<port>/<64桁トークン>/` で、トークンを知る端末だけが
/// 操作できます。各要求は次の順で検査します。
/// 1. 送信元がループバックまたはプライベートIPv4か（403）
/// 2. 送信元ごとの回数制限（429）
/// 3. 同時処理数（503）
/// 4. Hostが自分のアドレスか（DNSリバインディング対策, 421）
/// 5. APIはOriginが同一オリジンか（403）、JSONか（415）、4KiB以内か（413）
class RemoteServer {
  RemoteServer({
    required this.port,
    required this.backend,
    required this.loadPage,
    required this.onLog,
    this.requestDeadline = const Duration(seconds: 30),
  });

  /// 1件の要求にかける時間の上限です。DAMを待つ最長（22秒）より長くします。
  /// 過ぎた要求は接続を切って枠を返し、同時処理数の上限が埋まったままにならないようにします。
  final Duration requestDeadline;

  static const int maximumConcurrentRequests = 8;
  static const int maximumRequestsPerMinute = 180;
  static const int maximumBodyBytes = 4096;
  static const Duration bodyTimeout = Duration(seconds: 5);

  final int port;
  final RemoteBackend backend;
  final Future<String> Function() loadPage;
  final void Function(String message) onLog;

  final String token = randomHex(32);
  final Map<String, List<DateTime>> _requestTimes = <String, List<DateTime>>{};
  Set<String> _localAddresses = <String>{};
  String? _preferredAddress;
  final Set<_Trace> _inFlight = <_Trace>{};
  DateTime? _lastBusyLog;
  final Map<String, DateTime> _lastFailureLogs = <String, DateTime>{};
  HttpServer? _server;
  Timer? _addressTimer;

  /// スマホで開くURLです。LANのIPv4が見つからない場合は `null` です。
  String? get url => _preferredAddress == null
      ? null
      : 'http://$_preferredAddress:$port/$token/';

  /// 起動します。LANアドレスが変わったときは [onAddressChanged] を呼びます。
  Future<void> start({void Function()? onAddressChanged}) async {
    await _refreshAddresses();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    server.idleTimeout = const Duration(seconds: 15);
    _server = server;
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object error) => onLog('リモコンサーバーエラー: $error'),
    );
    _addressTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final before = url;
      await _refreshAddresses();
      if (url != before) onAddressChanged?.call();
    });
    onLog('リモコンサーバー起動: ${url ?? 'LANアドレスが見つかりません'}');
  }

  Future<void> stop() async {
    _addressTimer?.cancel();
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _refreshAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      _localAddresses = <String>{
        for (final interface in interfaces)
          for (final address in interface.addresses) address.address,
      };
      _preferredAddress = preferredLanAddress(interfaces);
    } on SocketException catch (error) {
      onLog('ネットワークアドレスを取得できません: $error');
    }
  }

  /// 仮想アダプタより実機のWi-Fi・有線を優先してLANアドレスを選びます。
  static String? preferredLanAddress(List<NetworkInterface> interfaces) {
    String? best;
    var bestScore = -1 << 30;
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      var score = 0;
      if (name.contains('wi-fi') || name.contains('wlan')) score += 30;
      if (name.contains('ethernet') || name.contains('イーサネット')) score += 20;
      if (const <String>[
        'virtual',
        'vethernet',
        'vmware',
        'virtualbox',
        'tailscale',
        'wsl',
        'hyper-v',
      ].any(name.contains)) {
        score -= 100;
      }
      for (final address in interface.addresses) {
        if (address.isLoopback || !isPrivateAddress(address)) continue;
        if (score > bestScore) {
          best = address.address;
          bestScore = score;
        }
      }
    }
    return best;
  }

  /// ループバック、RFC1918、リンクローカル(169.254/16)のIPv4かどうかです。
  static bool isPrivateAddress(InternetAddress? address) {
    if (address == null) return false;
    if (address.isLoopback) return true;
    if (address.type != InternetAddressType.IPv4) return false;
    final b = address.rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254);
  }

  bool _allowRate(String client) {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(minutes: 1));
    final times = _requestTimes.putIfAbsent(client, () => <DateTime>[])
      ..removeWhere((time) => time.isBefore(cutoff));
    if (_requestTimes.length > 128) {
      _requestTimes.removeWhere((_, value) => value.isEmpty);
    }
    if (times.length >= maximumRequestsPerMinute) return false;
    times.add(now);
    return true;
  }

  bool _isOwnHost(String? host) {
    if (host == null) return false;
    final name = host.toLowerCase();
    return name == 'localhost' ||
        name == '127.0.0.1' ||
        _localAddresses.contains(name);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    _securityHeaders(response.headers);
    final client = request.connectionInfo?.remoteAddress;
    if (!isPrivateAddress(client)) {
      return _send(response, HttpStatus.forbidden, _error('家庭内LANからのみ利用できます'));
    }
    if (!_allowRate(client!.address)) {
      return _send(
        response,
        HttpStatus.tooManyRequests,
        _error('操作が多すぎます。少し待ってから再試行してください'),
      );
    }
    if (_inFlight.length >= maximumConcurrentRequests) {
      _logBusy();
      return _send(
        response,
        HttpStatus.serviceUnavailable,
        _error('混み合っています。少し待ってから再読み込みしてください'),
      );
    }
    final trace = _Trace(request);
    _inFlight.add(trace);
    // 応答を受け取らない端末（画面消灯・電波切れなど）への送信待ちで止まらないよう、
    // 期限が来たら接続ごと切ります。
    response.deadline = requestDeadline;
    try {
      // どこで止まっても、期限を少し過ぎたら待つのをやめて枠を返します。
      await _route(
        request,
        trace,
      ).timeout(requestDeadline + const Duration(seconds: 1), onTimeout: () {});
      if (_pastDeadline(trace)) _logDeadline(trace);
    } on Object catch (error) {
      // 期限で接続を切った後のエラーです。応答はもう送れません。
      if (_pastDeadline(trace)) {
        _logDeadline(trace);
        return;
      }
      final (status, message) = _describe(error);
      if (error is RemoteFailure) {
        _logFailure(trace, error);
      } else if (status >= 500) {
        onLog('リモコンAPI失敗: $error');
      }
      trace.stage = 'エラー応答の送信';
      await _send(
        response,
        status,
        _error(message),
      ).timeout(requestDeadline, onTimeout: () {});
    } finally {
      _inFlight.remove(trace);
    }
  }

  /// 期限を過ぎていれば、Dartの [HttpResponse.deadline] がすでに接続を切っています。
  bool _pastDeadline(_Trace trace) =>
      DateTime.now().difference(trace.started) >= requestDeadline;

  void _logDeadline(_Trace trace) => onLog(
    'リモコンの要求が${requestDeadline.inSeconds}秒以内に終わらなかったため、接続を切りました'
    '（${trace.describe()}）',
  );

  /// DAMでの操作の失敗を、理由とともに記録します。状態の定期取得などで同じ失敗が
  /// 続いても埋もれないよう、同じ操作・同じ理由の記録は30秒に1回までにします。
  void _logFailure(_Trace trace, RemoteFailure failure) {
    final key = '${trace.target}:${failure.message}';
    final now = DateTime.now();
    final last = _lastFailureLogs[key];
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastFailureLogs[key] = now;
    if (_lastFailureLogs.length > 100) {
      _lastFailureLogs.remove(_lastFailureLogs.keys.first);
    }
    onLog(
      'リモコン操作失敗 (${trace.target}・${failure.kind.name}・'
      '${now.difference(trace.started).inMilliseconds}ms): ${failure.message}',
    );
  }

  /// 同時処理数が上限に達したことを、処理中の要求の内訳とともに記録します（30秒に1回まで）。
  void _logBusy() {
    final now = DateTime.now();
    final last = _lastBusyLog;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastBusyLog = now;
    final oldest = _inFlight.toList()
      ..sort((a, b) => a.started.compareTo(b.started));
    onLog(
      'リモコンの同時要求が上限（$maximumConcurrentRequests件）に達しています: '
      '${oldest.take(4).map((t) => t.describe()).join(' / ')}',
    );
  }

  Future<void> _route(HttpRequest request, _Trace trace) async {
    if (!_isOwnHost(request.requestedUri.host)) {
      throw const _Problem(HttpStatus.misdirectedRequest, '不明なホストです');
    }
    final segments = request.uri.pathSegments;
    if (segments.isEmpty || segments.first != token) {
      throw const _Problem(HttpStatus.notFound, '見つかりません');
    }
    if (segments.length == 1 || (segments.length == 2 && segments[1].isEmpty)) {
      if (request.method != 'GET') {
        throw const _Problem(HttpStatus.methodNotAllowed, '許可されていない操作です');
      }
      trace.stage = 'ページの送信';
      return _sendPage(request.response);
    }
    if (segments.length != 3 || segments[1] != 'api') {
      throw const _Problem(HttpStatus.notFound, '見つかりません');
    }
    if (request.method != 'POST') {
      throw const _Problem(HttpStatus.methodNotAllowed, '許可されていない操作です');
    }
    final origin = request.headers.value('origin');
    if (origin != null &&
        origin != 'http://${request.headers.value(HttpHeaders.hostHeader)}') {
      throw const _Problem(HttpStatus.forbidden, '別のサイトからの操作は拒否しました');
    }
    if (request.headers.contentType?.mimeType != 'application/json') {
      throw const _Problem(HttpStatus.unsupportedMediaType, 'JSONで送信してください');
    }
    trace.stage = '本文の受信';
    final body = await _readJson(request);
    trace.stage = 'DAMの応答待ち';
    final result = await _dispatch(segments[2], body);
    trace.stage = '応答の送信';
    await _send(request.response, HttpStatus.ok, result);
  }

  Future<Map<String, Object?>> _dispatch(
    String endpoint,
    Map<String, Object?> body,
  ) async {
    switch (endpoint) {
      case 'search':
        final query = body['query'];
        final mode = body['mode'] == null
            ? RemoteSearchMode.keyword
            : RemoteSearchMode.fromBrowser(body['mode']);
        if (query is! String) {
          throw const _Problem(HttpStatus.badRequest, '検索語を入力してください');
        }
        if (mode == null) {
          throw const _Problem(HttpStatus.badRequest, '無効な検索種別です');
        }
        final songs = await backend.search(query, mode);
        return <String, Object?>{
          'songs': <Object>[for (final song in songs) song.toJson()],
        };
      case 'history':
        final songs = await backend.search('', RemoteSearchMode.history);
        return <String, Object?>{
          'rows': <Object>[for (final song in songs) song.toJson()],
        };
      case 'detail':
        return <String, Object?>{
          'detail': (await backend.detail(_songToken(body))).toJson(),
        };
      case 'reserve':
        final mode = body['mode'] == null
            ? RemoteReservationMode.normal
            : enumByName(RemoteReservationMode.values, body['mode']);
        final playType = body['playType'] == null
            ? RemotePlayType.standard
            : enumByName(RemotePlayType.values, body['playType']);
        final key = body['key'];
        if (mode == null) {
          throw const _Problem(HttpStatus.badRequest, '無効な予約方法です');
        }
        if (playType == null) {
          throw const _Problem(HttpStatus.badRequest, '無効な演奏タイプです');
        }
        if (key is! num ||
            key != key.roundToDouble() ||
            key < minimumKey ||
            key > maximumKey) {
          throw const _Problem(HttpStatus.badRequest, 'キーは-7～+7で指定してください');
        }
        final result = await backend.reserve(
          _songToken(body),
          RemoteReservationOptions(
            mode: mode,
            key: key.toInt(),
            scoring: body['scoring'] == true,
            playType: playType,
          ),
        );
        return result.toJson();
      case 'favorite':
        final favorite = body['favorite'];
        if (favorite is! bool) {
          throw const _Problem(HttpStatus.badRequest, '無効なお気に入り操作です');
        }
        return (await backend.favorite(
          _songToken(body),
          add: favorite,
        )).toJson();
      case 'state':
        return (await backend.controlState()).toJson();
      case 'control':
        final action = enumByName(RemoteControlAction.values, body['action']);
        if (action == null) {
          throw const _Problem(HttpStatus.badRequest, '無効な再生操作です');
        }
        return (await backend.control(action)).toJson();
      case 'queue':
        return _rows(await backend.queue());
      case 'queue-action':
        final action = enumByName(RemoteQueueAction.values, body['action']);
        final token = body['token'];
        if (action == null || !isQueueToken(token)) {
          throw const _Problem(HttpStatus.badRequest, '無効な予約操作です');
        }
        return _rows(await backend.queueAction(action, token! as String));
      default:
        throw const _Problem(HttpStatus.notFound, '見つかりません');
    }
  }

  static Map<String, Object?> _rows(List<RemoteQueueEntry> rows) =>
      <String, Object?>{
        'rows': <Object>[for (final row in rows) row.toJson()],
      };

  static String _songToken(Map<String, Object?> body) {
    final token = body['token'];
    if (!isSongToken(token)) {
      throw const _Problem(HttpStatus.badRequest, '無効な検索結果です。もう一度検索してください');
    }
    return token! as String;
  }

  /// 本文を上限・時間制限付きで読みます。
  ///
  /// 宣言長が上限を少し超える程度なら読み捨ててから413を返し（クライアントが
  /// 接続断ではなくエラー応答を受け取れるように）、それ以上は接続ごと閉じます。
  static Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    if (request.contentLength > maximumBodyBytes) {
      request.response.persistentConnection = false;
      if (request.contentLength <= 16 * maximumBodyBytes) {
        await request.drain<void>().timeout(bodyTimeout, onTimeout: () {});
      }
      throw const _Problem(HttpStatus.requestEntityTooLarge, '要求が大きすぎます');
    }
    const tooLarge = _Problem(HttpStatus.requestEntityTooLarge, '要求が大きすぎます');
    final builder = BytesBuilder(copy: false);
    var received = 0;
    final subscription = request.timeout(bodyTimeout).listen(null);
    final done = Completer<void>();
    subscription
      ..onData((chunk) {
        received += chunk.length;
        if (received <= maximumBodyBytes) {
          builder.add(chunk);
        } else if (received > 16 * maximumBodyBytes && !done.isCompleted) {
          request.response.persistentConnection = false;
          done.completeError(tooLarge);
          unawaited(subscription.cancel());
        }
      })
      ..onError((Object error) {
        if (!done.isCompleted) {
          done.completeError(
            const _Problem(HttpStatus.requestTimeout, '受信がタイムアウトしました'),
          );
        }
      })
      ..onDone(() {
        if (done.isCompleted) return;
        if (received > maximumBodyBytes) {
          done.completeError(tooLarge);
        } else {
          done.complete();
        }
      });
    await done.future;
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(builder.takeBytes()));
    } on FormatException {
      throw const _Problem(HttpStatus.badRequest, 'JSONを解釈できません');
    }
    return jsonObject(decoded) ??
        (throw const _Problem(HttpStatus.badRequest, 'JSONオブジェクトで送信してください'));
  }

  Future<void> _sendPage(HttpResponse response) async {
    final page = await loadPage();
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(page);
    await response.close();
  }

  static (int, String) _describe(Object error) => switch (error) {
    _Problem(:final status, :final message) => (status, message),
    FormatException(:final message) => (HttpStatus.badRequest, message),
    RemoteFailure(kind: RemoteFailureKind.notConnected, :final message) => (
      HttpStatus.serviceUnavailable,
      message,
    ),
    RemoteFailure(kind: RemoteFailureKind.busy) => (
      HttpStatus.conflict,
      'DAMが別の操作を処理中です。少し待ってから再試行してください',
    ),
    RemoteFailure(kind: RemoteFailureKind.expired) => (
      HttpStatus.conflict,
      '検索結果の有効期限が切れました。もう一度検索してください',
    ),
    RemoteFailure(kind: RemoteFailureKind.timeout, :final message) => (
      HttpStatus.gatewayTimeout,
      message,
    ),
    RemoteFailure(:final message) => (HttpStatus.serviceUnavailable, message),
    _ => (HttpStatus.internalServerError, '内部エラーが発生しました'),
  };

  static Map<String, Object?> _error(String message) => <String, Object?>{
    'error': message,
  };

  static void _securityHeaders(HttpHeaders headers) => headers
    ..set(HttpHeaders.cacheControlHeader, 'no-store')
    ..set('X-Content-Type-Options', 'nosniff')
    ..set('X-Frame-Options', 'DENY')
    ..set('Referrer-Policy', 'no-referrer')
    ..set(
      'Content-Security-Policy',
      "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
          "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    );

  static Future<void> _send(
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) async {
    try {
      response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await response.close();
    } on Object {
      // 送信済み・切断済みの場合は何もしません。
    }
  }
}

/// 処理中の要求1件分です。止まったときに、どこで止まったかを記録に残すために使います。
class _Trace {
  _Trace(HttpRequest request)
    : method = request.method,
      target = _targetOf(request.uri.pathSegments);

  final String method;
  final String target;
  final DateTime started = DateTime.now();
  String stage = '受付';

  /// URLのトークンは記録に残さず、APIの種類だけを返します。
  static String _targetOf(List<String> segments) {
    if (segments.length == 3 &&
        segments[1] == 'api' &&
        RegExp(r'^[a-z-]{1,20}$').hasMatch(segments[2])) {
      return 'api/${segments[2]}';
    }
    if (segments.length <= 2) return 'ページ';
    return '不明';
  }

  String describe() =>
      '$method $target・$stage・${DateTime.now().difference(started).inSeconds}秒';
}

class _Problem implements Exception {
  const _Problem(this.status, this.message);

  final int status;
  final String message;
}
