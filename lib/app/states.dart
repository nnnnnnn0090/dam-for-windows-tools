import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../domain/scoring.dart';
import '../domain/tracks.dart';
import '../domain/update.dart';
import '../infra/helper/dam_link.dart';

/// 診断ログです。通知は100msごとにまとめ、ログが多くても画面を再構築し過ぎません。
class LogState extends ChangeNotifier {
  static const int maximumEntries = 500;

  final ListQueue<String> _entries = ListQueue<String>();
  Timer? _pending;

  List<String> get entries => List<String>.unmodifiable(_entries);

  void add(String message) {
    final time = DateTime.now().toIso8601String().substring(11, 23);
    _entries.add('$time $message');
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
