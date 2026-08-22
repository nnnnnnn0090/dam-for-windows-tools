// Project: DAM for Windows Tools
// File: media/hls_transcoder.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/tracks.dart';
import '../app_paths.dart';
import 'media_events.dart';
import 'media_job.dart';

class HlsTranscoder {
  HlsTranscoder({
    required this.paths,
    required this.onStage,
    required this.onLog,
    required this.isStopping,
  });

  static final RegExp segmentName = RegExp(r'^segment_[0-9]{6}\.ts$');

  final AppPaths paths;
  final PlaybackStageHandler onStage;
  final DiagnosticLogHandler onLog;
  final bool Function() isStopping;
  final Set<Process> _processes = <Process>{};

  void ensureStarted(MediaJob job) {
    if (job.transcodeStarted) return;
    job.transcodeStarted = true;
    unawaited(_run(job));
  }

  Future<void> stop() async {
    final processes = _processes.toList(growable: false);
    for (final process in processes) {
      process.kill();
    }
    await Future.wait<void>(
      processes.map((process) async {
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
        }
      }),
    );
    _processes.clear();
  }

  Future<void> _run(MediaJob job) async {
    final sources = <String>[
      if (job.manualSource != null) job.manualSource!.path,
      if (job.manualSource == null && job.highUrl != null)
        job.highUrl.toString(),
      if (job.manualSource == null &&
          job.lowUrl != null &&
          job.lowUrl != job.highUrl)
        job.lowUrl.toString(),
    ];
    for (var index = 0; index < sources.length && !isStopping(); index += 1) {
      if (job.forceFallback) break;
      final source = sources[index];
      try {
        if (await job.outputDirectory.exists()) {
          await job.outputDirectory.delete(recursive: true);
        }
        await job.outputDirectory.create(recursive: true);
        job.firstSegmentsReported = false;
        final result = await _runAttempt(job, source);
        if (result) {
          if (!job.completed.isCompleted) job.completed.complete(true);
          onStage(job.videoId, PlaybackStage.preparing, '全尺HLSの準備完了');
          return;
        }
        if (index + 1 < sources.length) {
          onLog('[${job.videoId}] high bitrate失敗。low bitrateで再試行します');
        }
      } on Object catch (error) {
        onLog('[${job.videoId}] FFmpeg起動失敗: $error');
      }
    }
    job.forceFallback = true;
    if (!job.completed.isCompleted) job.completed.complete(false);
    onStage(job.videoId, PlaybackStage.officialFallback, 'HLS生成失敗のため公式へ退避');
  }

  Future<bool> _runAttempt(MediaJob job, String source) async {
    final segmentPattern = p.join(job.outputDirectory.path, 'segment_%06d.ts');
    final indexPath = p.join(job.outputDirectory.path, 'index.m3u8');
    final process = await Process.start(
      paths.ffmpegExecutable,
      _arguments(job, source, segmentPattern, indexPath),
      runInShell: paths.ffmpegExecutable == 'ffmpeg',
    );
    job.ffmpegProcess = process;
    _processes.add(process);
    final errors = <String>[];
    final stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.isNotEmpty) {
            errors.add(line);
            if (errors.length > 20) errors.removeAt(0);
          }
        });
    unawaited(process.stdout.drain<void>());
    final exit = process.exitCode;
    while (!isStopping()) {
      final outcome = await Future.any<Object>(<Future<Object>>[
        exit.then<Object>((code) => code),
        Future<Object>.delayed(const Duration(milliseconds: 100), () => 'tick'),
      ]);
      if (!job.firstSegmentsReported &&
          await _hasPlayableOutput(job.outputDirectory)) {
        job.firstSegmentsReported = true;
        onStage(job.videoId, PlaybackStage.preparing, '先頭2セグメント生成済み・全尺を生成中');
      }
      if (outcome is int) {
        await stderrSubscription.cancel();
        _processes.remove(process);
        job.ffmpegProcess = null;
        final completeOutput =
            outcome == 0 && await _hasCompleteOutput(job.outputDirectory);
        if (!completeOutput && errors.isNotEmpty) {
          onLog('[${job.videoId}] ${errors.join(' | ')}');
        }
        return completeOutput;
      }
    }
    process.kill();
    final exitCode = await exit;
    await stderrSubscription.cancel();
    _processes.remove(process);
    job.ffmpegProcess = null;
    if (job.firstSegmentsReported && exitCode != 0) {
      onLog('[${job.videoId}] HLS生成中にFFmpegが異常終了しました (exit $exitCode)');
    }
    return false;
  }

  List<String> _arguments(
    MediaJob job,
    String source,
    String segmentPattern,
    String indexPath,
  ) {
    return <String>[
      '-nostdin',
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      '-fflags',
      '+genpts',
      '-avoid_negative_ts',
      'make_zero',
      if (source.startsWith('http://') ||
          source.startsWith('https://')) ...<String>['-rw_timeout', '15000000'],
      '-i',
      source,
      if (job.skipMs > 0) ...<String>[
        '-ss',
        (job.skipMs / 1000).toStringAsFixed(6),
      ],
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      '-c:v',
      'libx264',
      '-vf',
      'scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2',
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
      segmentPattern,
      indexPath,
    ];
  }

  Future<bool> _hasPlayableOutput(Directory output) async {
    final index = File(p.join(output.path, 'index.m3u8'));
    if (!await index.exists() || await index.length() == 0) return false;
    var segments = 0;
    await for (final entity in output.list(followLinks: false)) {
      if (entity is File && segmentName.hasMatch(p.basename(entity.path))) {
        if (await entity.length() > 0) segments += 1;
      }
      if (segments >= 2) return true;
    }
    return false;
  }

  Future<bool> _hasCompleteOutput(Directory output) async {
    if (!await _hasPlayableOutput(output)) return false;
    final index = File(p.join(output.path, 'index.m3u8'));
    try {
      final manifest = await index.readAsString();
      return manifest.contains('#EXT-X-ENDLIST');
    } on FileSystemException {
      return false;
    }
  }
}
