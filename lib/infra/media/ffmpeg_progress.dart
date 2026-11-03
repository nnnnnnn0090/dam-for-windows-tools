import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// FFmpeg に処理済みの時間を標準出力へ書かせる引数です（0.5秒ごと）。
const List<String> ffmpegProgressArguments = <String>[
  '-progress',
  'pipe:1',
  '-stats_period',
  '0.5',
];

/// 変換・書き出しの進み具合です。全体の長さが分からないときは [fraction] が `null` です。
class MediaProgress {
  const MediaProgress({required this.processed, this.total});

  final Duration processed;
  final Duration? total;

  double? get fraction {
    final total = this.total;
    if (total == null || total <= Duration.zero) return null;
    return (processed.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0);
  }

  /// `1:23 / 4:40` の形です。
  String describe() {
    final total = this.total;
    return total == null
        ? formatClock(processed)
        : '${formatClock(processed)} / ${formatClock(total)}';
  }
}

/// `m:ss` の形の時間です。
String formatClock(Duration duration) {
  final seconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

final RegExp _outTime = RegExp(r'^out_time_(?:us|ms)=(\d+)$');

/// `-progress` の出力（`key=value` の行）から、処理済みの時間を取り出します。
///
/// `out_time_us` と `out_time_ms` は、どちらもマイクロ秒です（FFmpeg の表記揺れ）。
Stream<Duration> parseFfmpegProgress(Stream<List<int>> output) => output
    .transform(const Utf8Decoder(allowMalformed: true))
    .transform(const LineSplitter())
    .map((line) => _outTime.firstMatch(line.trim()))
    .where((match) => match != null)
    .map((match) => Duration(microseconds: int.parse(match!.group(1)!)));

final RegExp _duration = RegExp(r'Duration: (\d+):(\d{2}):(\d{2}(?:\.\d+)?)');

/// 動画の長さを調べます。分からないとき（生配信など）や失敗したときは `null` です。
Future<Duration?> probeDuration(
  String ffmpeg,
  String source, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final remote = source.startsWith('http://') || source.startsWith('https://');
  final Process process;
  try {
    // 出力先を付けずに実行すると、入力の情報だけを表示して終了します。
    process = await Process.start(ffmpeg, <String>[
      '-hide_banner',
      '-nostdin',
      if (remote) ...<String>['-rw_timeout', '15000000'],
      '-i',
      source,
    ]);
  } on Object {
    return null;
  }
  unawaited(process.stdout.drain<void>().catchError((Object _) {}));
  final info = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join()
      .catchError((Object _) => '');
  var timedOut = false;
  await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      timedOut = true;
      process.kill();
      return -1;
    },
  );
  if (timedOut) return null;
  final match = _duration.firstMatch(await info);
  if (match == null) return null;
  final seconds =
      int.parse(match.group(1)!) * 3600 +
      int.parse(match.group(2)!) * 60 +
      double.parse(match.group(3)!);
  return Duration(microseconds: (seconds * 1000000).round());
}
