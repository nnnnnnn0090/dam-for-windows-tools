import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dam_for_windows_tools/app/states.dart';
import 'package:dam_for_windows_tools/infra/media/ffmpeg_progress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final String ffmpeg = p.join(
  Directory.current.path,
  'tool',
  'cache',
  'ffmpeg',
  'ffmpeg.exe',
);

void main() {
  group('TaskState', () {
    test('作業の開始・終了はすぐ知らせ、途中の更新はまとめて知らせる', () async {
      final tasks = TaskState();
      var notified = 0;
      tasks.addListener(() => notified++);

      tasks.update(TaskKind.transcode, '1-1', fraction: 0);
      expect(notified, 1);
      expect(tasks.forVideo('1-1')!.label, '変換中 0%');

      for (var i = 1; i <= 20; i++) {
        tasks.update(TaskKind.transcode, '1-1', fraction: i / 20);
      }
      expect(notified, 1, reason: '途中の更新はすぐには知らせない');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(notified, 2);
      expect(tasks.forVideo('1-1')!.label, '変換中 100%');

      tasks.end(TaskKind.transcode, '1-1');
      expect(notified, 3);
      expect(tasks.isEmpty, isTrue);
      tasks.dispose();
    });

    test('同じ曲の別の作業は別々に扱い、最後に始まったものを行に出す', () {
      final tasks = TaskState()
        ..update(TaskKind.import, '1-1', fraction: 0.5)
        ..update(TaskKind.transcode, '1-1');
      expect(tasks.all, hasLength(2));
      expect(tasks.forVideo('1-1')!.kind, TaskKind.transcode);
      expect(tasks.forVideo('1-1')!.label, '変換中');
      expect(tasks.isRunning(TaskKind.import, '1-1'), isTrue);
      tasks.end(TaskKind.transcode, '1-1');
      expect(tasks.forVideo('1-1')!.kind, TaskKind.import);
      tasks.dispose();
    });

    test('残り時間は進み具合から推定し、始まったばかりのときは出さない', () {
      final tasks = TaskState()..update(TaskKind.export, '1-1', fraction: 0.01);
      final task = tasks.forVideo('1-1')!;
      expect(task.remaining(), isNull);
      task.fraction = 0.25;
      final remaining = task.remaining(
        now: task.started.add(const Duration(seconds: 10)),
      );
      expect(remaining, const Duration(seconds: 30));
      tasks.dispose();
    });
  });

  group('FFmpeg の進み具合', () {
    test('-progress の出力から処理済みの時間を取り出す', () async {
      const output =
          'frame=10\nout_time_us=N/A\nout_time_us=1500000\n'
          'out_time_ms=2500000\nprogress=continue\nout_time=00:00:02.5\n';
      final times = await parseFfmpegProgress(
        Stream<List<int>>.value(utf8.encode(output)),
      ).toList();
      expect(times, const <Duration>[
        Duration(milliseconds: 1500),
        Duration(milliseconds: 2500),
      ]);
    });

    test('割合と表示', () {
      const progress = MediaProgress(
        processed: Duration(seconds: 83),
        total: Duration(minutes: 4, seconds: 40),
      );
      expect(progress.fraction, closeTo(83 / 280, 1e-9));
      expect(progress.describe(), '1:23 / 4:40');
      const unknown = MediaProgress(processed: Duration(seconds: 5));
      expect(unknown.fraction, isNull);
      expect(unknown.describe(), '0:05');
    });

    test(
      '動画の長さを調べる',
      () async {
        final temp = await Directory.systemTemp.createTemp('dam_tools_probe_');
        try {
          final source = p.join(temp.path, 'source.mp4');
          final made = await Process.run(ffmpeg, <String>[
            '-v', 'error', //
            '-f', 'lavfi', '-i', 'testsrc=size=160x120:rate=25:duration=3',
            '-y', source,
          ]);
          expect(made.exitCode, 0, reason: '${made.stderr}');
          final duration = await probeDuration(ffmpeg, source);
          expect(duration!.inMilliseconds, closeTo(3000, 100));
          expect(
            await probeDuration(ffmpeg, p.join(temp.path, 'missing.mp4')),
            isNull,
          );
        } finally {
          await temp.delete(recursive: true);
        }
      },
      skip: File(ffmpeg).existsSync()
          ? false
          : 'tool/bootstrap.ps1 でFFmpegを取得してください',
    );
  });
}
