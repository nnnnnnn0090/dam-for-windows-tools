import 'dart:io';

import 'package:dam_for_windows_tools/domain/tracks.dart';
import 'package:dam_for_windows_tools/infra/media/original_exporter.dart';
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
  test('既定のファイル名は動画ID・アーティスト・曲名で、使えない文字を置き換える', () {
    expect(
      exportFileName(
        const TrackRecord(
          videoId: '6343-36',
          artist: 'GARNET CROW',
          title: 'Holy ground',
        ),
      ),
      '6343-36 GARNET CROW - Holy ground.mp4',
    );
    expect(
      exportFileName(
        const TrackRecord(videoId: '1-1', artist: 'A/B', title: 'Why? <1>.'),
      ),
      '1-1 A／B - Why？ ＜1＞.mp4',
    );
    expect(
      exportFileName(const TrackRecord(videoId: '1-1', artist: '', title: '')),
      '1-1.mp4',
    );
  });

  group('OriginalExporter', () {
    late Directory temp;
    late HttpServer upstream;

    setUpAll(() async {
      temp = await Directory.systemTemp.createTemp('dam_tools_export_');
      final hls = Directory(p.join(temp.path, 'hls'))..createSync();
      // DAMの配信と同じ H.264 + AAC のHLSを作り、HTTPで配信します。
      final made = await Process.run(ffmpeg, <String>[
        '-nostdin', '-v', 'error', //
        '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=25:duration=4',
        '-f', 'lavfi', '-i', 'sine=duration=4',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
        '-f', 'hls', '-hls_time', '1', '-hls_playlist_type', 'vod',
        p.join(hls.path, 'index.m3u8'),
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        final file = File(p.join(hls.path, p.basename(request.uri.path)));
        if (await file.exists()) {
          await request.response.addStream(file.openRead());
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
    });

    tearDownAll(() async {
      await upstream.close(force: true);
      await temp.delete(recursive: true);
    });

    Uri url(String name) =>
        Uri.parse('http://127.0.0.1:${upstream.port}/$name');

    test('公式HLSを無変換でMP4へ書き出し、作業ファイルを残さない', () async {
      final output = File(p.join(temp.path, 'out dir', 'song.mp4'))
        ..parent.createSync();
      // 1つ目の候補が失敗しても、次の候補で書き出します。
      await OriginalExporter(ffmpeg: ffmpeg)
          .export(<Uri>[url('missing.m3u8'), url('index.m3u8')], output);
      expect(output.lengthSync(), greaterThan(1000));
      expect(File('${output.path}.part').existsSync(), isFalse);
      final probe = await Process.run(ffmpeg, <String>[
        '-v', 'error', '-i', output.path, '-f', 'null', '-', //
      ]);
      expect(probe.exitCode, 0, reason: '${probe.stderr}');
    });

    test('取得できないURLは、もう一度再生するよう案内する', () async {
      final output = File(p.join(temp.path, 'never.mp4'));
      await expectLater(
        OriginalExporter(ffmpeg: ffmpeg)
            .export(<Uri>[url('missing.m3u8')], output),
        throwsA(
          isA<ExportException>().having(
            (e) => e.message,
            'message',
            contains('もう一度再生'),
          ),
        ),
      );
      expect(output.existsSync(), isFalse);
      expect(File('${output.path}.part').existsSync(), isFalse);
    });
  });
}
