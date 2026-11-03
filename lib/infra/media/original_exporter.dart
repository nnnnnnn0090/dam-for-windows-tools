import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/tracks.dart';
import 'ffmpeg_progress.dart';

/// 保存画面に出す既定のファイル名です（`<動画ID> <アーティスト> - <曲名>.mp4`）。
///
/// Windowsのファイル名に使えない文字は全角に置き換えます。
String exportFileName(TrackRecord record) {
  const replacements = <String, String>{
    '<': '＜',
    '>': '＞',
    ':': '：',
    '"': '”',
    '/': '／',
    r'\': '＼',
    '|': '｜',
    '?': '？',
    '*': '＊',
  };
  String clean(String text) => text
      .split('')
      .map((c) => c.codeUnitAt(0) < 0x20 ? ' ' : replacements[c] ?? c)
      .join()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final label = <String>[
    clean(record.artist),
    clean(record.title),
  ].where((part) => part.isNotEmpty).join(' - ');
  var name = clean(label.isEmpty ? record.videoId : '${record.videoId} $label');
  if (name.length > 150) name = name.substring(0, 150).trim();
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  return '${name.isEmpty ? 'original' : name}.mp4';
}

/// DAMが再生した公式動画（HLS）を、無変換のままMP4へ書き出します。
///
/// 差し替え動画をタイミングに合わせて作るための元動画です。映像は再エンコードせず、
/// 音声がそのまま格納できない場合だけAACへ変換します。書き出し中のファイルは
/// `<出力>.part` に作り、完成してから出力名へ置き換えます。
class OriginalExporter {
  OriginalExporter({required this.ffmpeg});

  final String ffmpeg;
  final Set<Process> _running = <Process>{};
  bool _closed = false;

  /// [sources] を順に試し、最初に成功したものを [output] へ保存します。
  /// すべて失敗したら最後のFFmpegのエラーを含む [ExportException] を投げます。
  /// [onProgress] には、書き出し済みの時間と全体の長さ（分かれば）が届きます。
  Future<void> export(
    List<Uri> sources,
    File output, {
    void Function(MediaProgress progress)? onProgress,
  }) async {
    if (sources.isEmpty) throw const ExportException('公式動画のURLがありません');
    final part = File('${output.path}.part');
    var lastError = '';
    try {
      for (final source in sources) {
        // 全体の長さは書き出しと並行して調べ、再試行でも使い回します。
        Duration? total;
        unawaited(
          probeDuration(
            ffmpeg,
            source.toString(),
          ).then((duration) => total ??= duration),
        );
        for (final copyAudio in <bool>[true, false]) {
          if (_closed) throw const ExportException('アプリの終了により中止しました');
          onProgress?.call(
            MediaProgress(processed: Duration.zero, total: total),
          );
          final error = await _run(
            arguments(source, part, copyAudio: copyAudio),
            (processed) => onProgress?.call(
              MediaProgress(processed: processed, total: total),
            ),
          );
          if (error == null) {
            if (await output.exists()) await output.delete();
            await part.rename(output.path);
            return;
          }
          lastError = error;
        }
      }
    } finally {
      if (await part.exists()) {
        await part.delete().catchError((Object _) => part);
      }
    }
    throw ExportException(
      lastError.contains('403') || lastError.contains('404')
          ? '公式動画を取得できません（URLの期限切れの可能性があります）。DAMでもう一度再生してから書き出してください'
          : '書き出しに失敗しました: $lastError',
    );
  }

  /// 実行中の書き出しを止めます（アプリ終了時）。
  Future<void> close() async {
    _closed = true;
    for (final process in _running.toList()) {
      process.kill();
    }
    await Future.wait(
      _running.toList().map(
        (process) => process.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () => -1,
        ),
      ),
    );
  }

  /// 成功なら `null`、失敗ならFFmpegのエラー出力（末尾数行）を返します。
  Future<String?> _run(
    List<String> args,
    void Function(Duration processed) onProcessed,
  ) async {
    final process = await Process.start(ffmpeg, args);
    _running.add(process);
    final progressDone = parseFfmpegProgress(process.stdout)
        .forEach(onProcessed)
        .catchError((Object _) {});
    final errors = <String>[];
    final stderrDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((line) {
          if (line.trim().isEmpty) return;
          errors.add(line.trim());
          if (errors.length > 8) errors.removeAt(0);
        })
        .catchError((Object _) {});
    final code = await process.exitCode;
    _running.remove(process);
    await stderrDone;
    await progressDone;
    if (code == 0) return null;
    return errors.isEmpty ? '終了コード $code' : errors.join(' | ');
  }

  static List<String> arguments(
    Uri source,
    File output, {
    required bool copyAudio,
  }) => <String>[
    '-nostdin',
    '-y',
    '-hide_banner',
    '-loglevel',
    'error',
    ...ffmpegProgressArguments,
    '-rw_timeout',
    '15000000',
    '-i',
    source.toString(),
    '-map',
    '0:v:0',
    '-map',
    '0:a:0?',
    '-c:v',
    'copy',
    if (copyAudio) ...<String>[
      '-c:a',
      'copy',
      '-bsf:a',
      'aac_adtstoasc',
    ] else ...<String>['-c:a', 'aac', '-b:a', '192k'],
    '-movflags',
    '+faststart',
    '-f',
    'mp4',
    output.path,
  ];
}

class ExportException implements Exception {
  const ExportException(this.message);

  final String message;

  @override
  String toString() => message;
}
