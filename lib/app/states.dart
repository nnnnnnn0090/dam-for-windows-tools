import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/scoring.dart';
import '../domain/tracks.dart';
import '../domain/update.dart';
import '../infra/helper/dam_link.dart';

/// 同じキーを、間を空けずに決まった回数続けて押したかを判定します（隠し機能の表示用）。
class KeySequence {
  KeySequence({
    required this.count,
    this.maximumGap = const Duration(seconds: 2),
  });

  final int count;
  final Duration maximumGap;
  int _pressed = 0;
  DateTime? _last;

  /// キーが押されるたびに呼びます。[count] 回目の連続押下で `true` を返します。
  bool press({required bool matches, required DateTime at}) {
    final last = _last;
    if (!matches || (last != null && at.difference(last) > maximumGap)) {
      _pressed = 0;
    }
    _last = at;
    if (!matches) return false;
    _pressed++;
    if (_pressed < count) return false;
    _pressed = 0;
    return true;
  }
}

/// 診断ログです。通知は100msごとにまとめ、ログが多くても画面を再構築し過ぎません。
class LogState extends ChangeNotifier {
  static const int maximumEntries = 500;

  final ListQueue<String> _entries = ListQueue<String>();
  Timer? _pending;
  IOSink? _file;

  List<String> get entries => List<String>.unmodifiable(_entries);

  /// 以後のログを [file] にも書きます（前回分は `.old` として1世代だけ残します）。
  /// 画面のログは500件で消えるため、後から不具合を調べられるようにします。
  Future<void> attachFile(File file) async {
    try {
      final old = File('${file.path}.old');
      if (await file.exists()) {
        if (await old.exists()) await old.delete();
        await file.rename(old.path);
      }
      _file = file.openWrite(encoding: utf8);
      for (final entry in _entries) {
        _file!.writeln(entry);
      }
    } on FileSystemException catch (error) {
      add('診断ログをファイルへ書けません: ${error.message}');
    }
  }

  Future<void> closeFile() async {
    final sink = _file;
    _file = null;
    await sink?.close().catchError((Object _) {});
  }

  void add(String message) {
    final time = DateTime.now().toIso8601String().substring(11, 23);
    _entries.add('$time $message');
    _file?.writeln('$time $message');
    while (_entries.length > maximumEntries) {
      _entries.removeFirst();
    }
    if (kDebugMode) debugPrint('$time $message');
    _pending ??= Timer(const Duration(milliseconds: 100), () {
      _pending = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _pending?.cancel();
    unawaited(closeFile());
    super.dispose();
  }
}

/// 接続ヘルパー・DAMの接続状態です。
class ConnectionState extends ChangeNotifier {
  LinkState state = LinkState.starting;
  String detail = '起動中';

  void update(LinkState next, String nextDetail) {
    if (state == next && detail == nextDetail) return;
    state = next;
    detail = nextDetail;
    notifyListeners();
  }
}

/// 再生履歴（新しい順）と、今回のセッションでの再生段階です。
class HistoryState extends ChangeNotifier {
  static const int maximumMetadata = 2000;

  final LinkedHashMap<String, TrackRecord> _records =
      LinkedHashMap<String, TrackRecord>(); // 挿入順 = 古い順
  final Map<String, PlaybackStage> _stages = <String, PlaybackStage>{};
  final LinkedHashMap<String, MetadataCandidate> _metadata =
      LinkedHashMap<String, MetadataCandidate>();
  List<TrackRecord>? _newestFirstCache;

  /// 新しい順の履歴です。
  List<TrackRecord> get records => _newestFirstCache ??= _records.values
      .toList()
      .reversed
      .toList(growable: false);

  PlaybackStage? stageOf(String videoId) => _stages[videoId];

  void restore(List<TrackRecord> newestFirst) {
    _records.clear();
    for (final record in newestFirst.reversed) {
      _records[record.videoId] = record;
    }
    _changed();
  }

  void clear() {
    _records.clear();
    _stages.clear();
    _changed();
  }

  /// 再生を記録して先頭へ移します。既知の曲情報があれば反映します。
  void registerPlayback(String videoId) {
    final metadata = _metadata[videoId];
    final existing = _records.remove(videoId);
    _records[videoId] = TrackRecord(
      videoId: videoId,
      artist: _pick(metadata?.artist, existing?.artist),
      title: _pick(metadata?.title, existing?.title),
    );
    _stages[videoId] = PlaybackStage.detected;
    _changed();
  }

  /// 曲情報候補を記憶し、該当する履歴を更新します。履歴が変わったら `true` です。
  bool acceptMetadata(Iterable<MetadataCandidate> candidates) {
    var changed = false;
    for (final candidate in candidates) {
      if (candidate.artist.isEmpty && candidate.title.isEmpty) continue;
      for (final id in candidate.ids) {
        _metadata.remove(id);
        _metadata[id] = candidate;
        final current = _records[id];
        if (current == null) continue;
        final next = current.copyWith(
          artist: _pick(candidate.artist, current.artist),
          title: _pick(candidate.title, current.title),
        );
        if (next.artist != current.artist || next.title != current.title) {
          _records[id] = next; // 既存キーへの代入は順序を変えません。
          changed = true;
        }
      }
    }
    while (_metadata.length > maximumMetadata) {
      _metadata.remove(_metadata.keys.first);
    }
    if (changed) _changed();
    return changed;
  }

  void markStage(String videoId, PlaybackStage stage) {
    if (_stages[videoId] == stage) return;
    _stages[videoId] = stage;
    notifyListeners();
  }

  void _changed() {
    _newestFirstCache = null;
    notifyListeners();
  }

  static String _pick(String? preferred, String? fallback) =>
      preferred != null && preferred.isNotEmpty ? preferred : fallback ?? '';
}

/// 採点中に検出した歌唱技法の回数です。回数は検出1回につき1加算します。
class ScoringState extends ChangeNotifier {
  final Map<int, int> _counts = <int, int>{};
  bool active = false;
  int? lastTechniqueId;

  int countOf(int canonicalId) => _counts[canonicalId] ?? 0;
  int get total => _counts.values.fold(0, (sum, value) => sum + value);

  void begin() {
    _counts.clear();
    lastTechniqueId = null;
    active = true;
    notifyListeners();
  }

  void deactivate() {
    if (!active) return;
    active = false;
    notifyListeners();
  }

  void reset() {
    _counts.clear();
    lastTechniqueId = null;
    notifyListeners();
  }

  void add({required int techniqueId, required int value}) {
    if (!isKnownTechniqueId(techniqueId) || value <= 0) return;
    final canonical = canonicalTechniqueId(techniqueId);
    _counts[canonical] = countOf(canonical) + 1;
    lastTechniqueId = techniqueId;
    active = true;
    notifyListeners();
  }
}

enum UpdatePhase {
  idle,
  checking,
  available,
  downloading,
  restarting,
  latest,
  failed,
}

/// 自動更新の進行状態です。
class UpdateState extends ChangeNotifier {
  UpdatePhase phase = UpdatePhase.idle;
  AppUpdate? available;
  int progressPercent = 0;
  String message = '更新を確認';

  bool get busy =>
      phase == UpdatePhase.checking ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.restarting;

  void set(UpdatePhase next, String nextMessage, {AppUpdate? update}) {
    phase = next;
    message = nextMessage;
    if (update != null) available = update;
    notifyListeners();
  }

  void progress(double fraction) {
    final percent = (fraction.clamp(0, 1) * 100).floor();
    if (percent == progressPercent) return;
    progressPercent = percent;
    message = '更新をダウンロード中 $percent%';
    notifyListeners();
  }
}

/// 時間のかかる作業の種類です。
enum TaskKind {
  import('取り込み'),
  transcode('変換'),
  export('書き出し');

  const TaskKind(this.label);
  final String label;
}

/// 時間のかかる作業1件の進み具合です。
class TaskProgress {
  TaskProgress._(this.kind, this.videoId, {DateTime? now})
    : started = now ?? DateTime.now();

  final TaskKind kind;
  final String videoId;
  final DateTime started;

  /// 0〜1。全体の量が分からないときは `null` です。
  double? fraction;

  /// `120.5MB / 300.0MB` や `1:23 / 4:40` などの補足です。
  String detail = '';

  /// `変換中 42%` の形です。
  String get label {
    final f = fraction;
    return f == null
        ? '${kind.label}中'
        : '${kind.label}中 ${(f * 100).floor()}%';
  }

  /// 残り時間の目安です。進み具合から推定するため、始まったばかりのときは `null` です。
  Duration? remaining({DateTime? now}) {
    final f = fraction;
    if (f == null || f < 0.03 || f >= 1) return null;
    final elapsed = (now ?? DateTime.now()).difference(started);
    return elapsed * ((1 - f) / f);
  }
}

/// 取り込み・変換・書き出しなど、裏で動いている作業の進み具合です。
///
/// 進捗の更新は頻繁に届くため、画面への通知は 0.25 秒に1回までにまとめます。
/// 作業の開始と終了はすぐに通知します。
class TaskState extends ChangeNotifier {
  final LinkedHashMap<String, TaskProgress> _tasks =
      LinkedHashMap<String, TaskProgress>();
  Timer? _pending;

  /// 始まった順の作業一覧です。
  List<TaskProgress> get all => _tasks.values.toList(growable: false);

  bool get isEmpty => _tasks.isEmpty;

  /// その動画で最後に始まった作業です。
  TaskProgress? forVideo(String videoId) {
    TaskProgress? found;
    for (final task in _tasks.values) {
      if (task.videoId == videoId) found = task;
    }
    return found;
  }

  bool isRunning(TaskKind kind, String videoId) =>
      _tasks.containsKey(_key(kind, videoId));

  /// 作業の進み具合を記録します。まだ始まっていなければ始めます。
  void update(
    TaskKind kind,
    String videoId, {
    double? fraction,
    String? detail,
  }) {
    final key = _key(kind, videoId);
    final task = _tasks[key];
    if (task == null) {
      _tasks[key] = TaskProgress._(kind, videoId)
        ..fraction = fraction
        ..detail = detail ?? '';
      notifyListeners();
      return;
    }
    if (fraction != null) task.fraction = fraction;
    if (detail != null) task.detail = detail;
    _pending ??= Timer(const Duration(milliseconds: 250), () {
      _pending = null;
      notifyListeners();
    });
  }

  void end(TaskKind kind, String videoId) {
    if (_tasks.remove(_key(kind, videoId)) == null) return;
    notifyListeners();
  }

  static String _key(TaskKind kind, String videoId) => '${kind.name}:$videoId';

  @override
  void dispose() {
    _pending?.cancel();
    super.dispose();
  }
}
