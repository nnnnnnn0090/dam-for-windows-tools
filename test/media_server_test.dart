import 'dart:convert';
import 'dart:io';

import 'package:dam_for_windows_tools/domain/tracks.dart';
import 'package:dam_for_windows_tools/infra/media/ffmpeg_progress.dart';
import 'package:dam_for_windows_tools/infra/media/manifest_rewriter.dart';
import 'package:dam_for_windows_tools/infra/media/media_server.dart';
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
  test('マニフェストのURL行とURI属性を中継URLへ書き換える', () {
    final registered = <String, Uri>{};
    final output = rewriteManifest(
      source:
          '#EXTM3U\r\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\r\nseg1.ts\r\n'
          'https://cdn.example.com/seg2.ts\r\n',
      baseUri: Uri.parse('https://origin.example.com/a/index.m3u8'),
      proxyPrefix: '/v1/t/j/proxy/',
      register: (id, uri) => registered[id] = uri,
    );
    expect(output, isNot(contains('\r')));
    expect(output, isNot(contains('example.com')));
    expect(registered.values.map((u) => u.toString()), <String>[
      'https://origin.example.com/a/key.bin',
      'https://origin.example.com/a/seg1.ts',
      'https://cdn.example.com/seg2.ts',
    ]);
  });

  group('MediaServer', () {
    late Directory temp;
    late MediaServer server;
    late HttpServer upstream;
    final stages = <PlaybackStage>[];
    final progress = <(String, MediaProgress?)>[];
    final client = HttpClient();

    setUp(() async {
      progress.clear();
      temp = await Directory.systemTemp.createTemp('dam_tools_media_');
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        if (request.uri.path.endsWith('.m3u8')) {
          request.response.write(
            '#EXTM3U\n#EXTINF:2,\nseg.ts\n#EXT-X-ENDLIST\n',
          );
        } else {
          request.response.add(List<int>.filled(1000, 7));
        }
        await request.response.close();
      });
      server = MediaServer(
        port: 0 + 18765,
        hlsDirectory: Directory(p.join(temp.path, 'hls')),
        ffmpeg: ffmpeg,
        onStage: (_, stage, _) => stages.add(stage),
        onLog: (_) {},
        onProgress: (id, value) => progress.add((id, value)),
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      await upstream.close(force: true);
      await temp.delete(recursive: true);
    });

    Future<(int, String)> get(String url) async {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      return (
        response.statusCode,
        utf8.decode(
          await response.expand((c) => c).toList(),
          allowMalformed: true,
        ),
      );
    }

    PlaybackDescriptor descriptor(String id) => PlaybackDescriptor(
      videoId: id,
      highUrl: Uri.parse('http://127.0.0.1:${upstream.port}/$id/index.m3u8'),
      lowUrl: null,
    );

    test('遅延補正0・差し替えなしは公式HLSを中継し、中継先も取得できる', () async {
      final url = server.register(descriptor('1-1'), skipMs: 0);
      final (status, body) = await get(url);
      expect(status, 200);
      expect(body, contains('/proxy/'));
      final proxied = body.split('\n').firstWhere((l) => l.contains('/proxy/'));
      final (assetStatus, _) = await get(
        Uri.parse(url).resolve(proxied).toString(),
      );
      expect(assetStatus, 200);
      expect(stages, contains(PlaybackStage.streaming));
    });

    test('トークン違い・未知ジョブ・POSTは拒否する', () async {
      final url = server.register(descriptor('1-1'), skipMs: 0);
      final wrongToken = url.replaceFirst(
        RegExp(r'/v1/[0-9a-f]+/'),
        '/v1/${'0' * 64}/',
      );
      expect((await get(wrongToken)).$1, 404);
      expect(
        (await get(
          url.replaceFirst(
            RegExp(r'/[0-9a-f]{32}/index'),
            '/${'a' * 32}/index',
          ),
        )).$1,
        404,
      );
      final post = await (await client.postUrl(Uri.parse(url))).close();
      expect(post.statusCode, 405);
      await post.drain<void>();
    });

    test('同じ曲・同じ条件の登録は同じURLを返し、上限を超えたら古いものを消す', () {
      final first = server.register(descriptor('1-1'), skipMs: 0);
      expect(server.register(descriptor('1-1'), skipMs: 0), first);
      for (var i = 2; i <= MediaServer.maximumJobs + 1; i++) {
        server.register(descriptor('$i-1'), skipMs: 0);
      }
      expect(server.register(descriptor('1-1'), skipMs: 0), isNot(first));
    });

    test(
      '差し替え動画を720p HLSへ変換して配信する',
      () async {
        final source = p.join(temp.path, 'source.mp4');
        final made = await Process.run(ffmpeg, <String>[
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'testsrc=size=320x240:rate=25:duration=5',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:duration=5',
          '-shortest',
          '-y',
          source,
        ]);
        expect(made.exitCode, 0, reason: '${made.stderr}');
        await server.setManualSource('9-9', File(source));
        final url = server.register(descriptor('9-9'), skipMs: 500);
        final (status, body) = await get(url);
        expect(status, 200);
        expect(body, contains('#EXT-X-ENDLIST'));
        final segment = body.split('\n').firstWhere((l) => l.endsWith('.ts'));
        final (segmentStatus, _) = await get(
          Uri.parse(url).resolve(segment).toString(),
        );
        expect(segmentStatus, 200);
        // 変換の進み具合が届き、最後に終了（null）が届く。
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!progress.any((e) => e.$2 == null) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(progress.every((e) => e.$1 == '9-9'), isTrue);
        expect(progress.last.$2, isNull);
        final fractions = progress
            .map((e) => e.$2?.fraction)
            .whereType<double>()
            .toList();
        expect(fractions, isNotEmpty);
        // 5秒の動画を0.5秒飛ばして変換するので、全体は約4.5秒
        expect(fractions.last, greaterThan(0.9));
        // 差し替え解除で変換結果も消え、元ファイルは解放されている。
        await server.setManualSource('9-9', null);
        await File(source).delete();
      },
      skip: File(ffmpeg).existsSync()
          ? false
          : 'tool/bootstrap.ps1 でFFmpegを取得してください',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
