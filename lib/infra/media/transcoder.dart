import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// FFmpegでDAM互換のHLS(720p H.264 baseline + AAC)を生成する1回分の処理です。
///
/// 入力候補（差し替え動画、または上流high→low）を順に試し、成功した時点で終わります。
/// 呼び出し側は [playable]（先頭2セグメント完成）と [finished] を待てます。
class Transcode {
  Transcode({
    required this.ffmpeg,
    required this.sources,
    required this.skipMs,
    required this.outputDirectory,
    required this.onLog,
  });

  static final RegExp segmentName = RegExp(r'^segment_[0-9]{6}\.ts$');
  static const String indexName = 'index.m3u8';

  final String ffmpeg;
  final List<String> sources;
  final int skipMs;
  final Directory outputDirectory;
  final void Function(String message) onLog;

  final Completer<void> _playable = Completer<void>();
  final Completer<bool> _finished = Completer<bool>();
  Process? _process;
  bool _cancelled = false;

  /// 先頭2セグメントが揃ったときに完了します（全体が失敗した場合は完了しません）。
  Future<void> get playable => _playable.future;

  /// 全尺の生成が終わったら `true`、全候補が失敗・中止なら `false` で完了します。
  Future<bool> get finished => _finished.future;
  bool get isFinished => _finished.isCompleted;

  File get index => File(p.join(outputDirectory.path, indexName));

  void start() => unawaited(_run());

  /// FFmpegを止め、終了を待ちます（差し替え動画のロック解除に必要）。
  Future<void> cancel() async {
    _cancelled = true;
    final process = _process;
    if (process != null) {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
    await finished;
  }

  Future<void> _run() async {
    var success = false;
    for (final source in sources) {
      if (_cancelled) break;
      try {
        await _resetOutput();
        success = await _attempt(source);
        if (success) break;
        onLog('FFmpegによる生成に失敗しました。次の入力候補を試します');
      } on Object catch (error) {
        onLog('FFmpegを起動できません: $error');
      }
    }
    if (!_finished.isCompleted) _finished.complete(success && !_cancelled);
  }

  Future<void> _resetOutput() async {
    if (await outputDirectory.exists()) {
      await outputDirectory.delete(recursive: true);
    }
    await outputDirectory.create(recursive: true);
  }

  Future<bool> _attempt(String source) async {
    final process = await Process.start(ffmpeg, arguments(source));
    _process = process;
    final errors = <String>[];
    final stderrDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((line) {
          if (line.trim().isEmpty) return;
          errors.add(line.trim());
          if (errors.length > 20) errors.removeAt(0);
        })
        .catchError((Object _) {});
    unawaited(process.stdout.drain<void>().catchError((Object _) {}));

    final watcher = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!_playable.isCompleted) unawaited(_checkPlayable());
    });
    final code = await process.exitCode;
    watcher.cancel();
    await stderrDone;
    _process = null;
    if (_cancelled) return false;
    final complete = code == 0 && await _isComplete();
    if (complete) {
      if (!_playable.isCompleted) _playable.complete();
    } else if (errors.isNotEmpty) {
      onLog('FFmpeg (終了コード $code): ${errors.join(' | ')}');
    }
    return complete;
  }

  Future<void> _checkPlayable() async {
    try {
      if (!await index.exists() || await index.length() == 0) return;
      var segments = 0;
      await for (final entity in outputDirectory.list(followLinks: false)) {
        if (entity is File &&
            segmentName.hasMatch(p.basename(entity.path)) &&
            await entity.length() > 0) {
          segments++;
        }
      }
      if (segments >= 2 && !_playable.isCompleted) _playable.complete();
    } on FileSystemException {
      // 生成中の一時ファイル入れ替えと競合した場合は次の確認で判定します。
    }
  }

  Future<bool> _isComplete() async {
    try {
      return (await index.readAsString()).contains('#EXT-X-ENDLIST');
    } on FileSystemException {
      return false;
    }
  }

  /// FFmpeg引数です。`-ss` は入力側に置き、先頭からの全デコードを避けます。
  List<String> arguments(String source) {
    final isRemote =
        source.startsWith('http://') || source.startsWith('https://');
    return <String>[
      '-nostdin',
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      '-fflags',
      '+genpts',
      if (isRemote) ...<String>['-rw_timeout', '15000000'],
      if (skipMs > 0) ...<String>['-ss', (skipMs / 1000).toStringAsFixed(3)],
      '-i',
      source,
      '-avoid_negative_ts',
      'make_zero',
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      '-vf',
      'scale=1280:720:force_original_aspect_ratio=decrease,'
          'pad=1280:720:(ow-iw)/2:(oh-ih)/2',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-crf',
      '22',
      '-profile:v',
      'baseline',
      '-level:v',
      '3.1',
      '-pix_fmt',
      'yuv420p',
      '-r',
      '30000/1001',
      '-g',
      '60',
      '-keyint_min',
      '60',
      '-sc_threshold',
      '0',
      '-force_key_frames',
      'expr:gte(t,n_forced*2)',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      '-ar',
      '48000',
      '-af',
      'aresample=async=1:first_pts=0',
      '-f',
      'hls',
      '-hls_time',
      '2',
      '-hls_list_size',
      '0',
      '-hls_playlist_type',
      'event',
      '-hls_flags',
      'independent_segments+temp_file',
      '-hls_segment_type',
      'mpegts',
      '-hls_segment_filename',
      p.join(outputDirectory.path, 'segment_%06d.ts'),
      index.path,
    ];
  }
}
