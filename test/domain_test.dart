import 'package:dam_for_windows_tools/domain/remote.dart';
import 'package:dam_for_windows_tools/domain/scoring.dart';
import 'package:dam_for_windows_tools/domain/update.dart';
import 'package:dam_for_windows_tools/domain/values.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('動画IDは公開形式だけを受け入れる', () {
    expect(normalizeVideoAssetId(' 6184-92 '), '6184-92');
    expect(normalizeVideoAssetId('6184'), '');
    expect(normalizeVideoAssetId('../6184-92'), '');
    expect(normalizeVideoAssetId(42), '');
  });

  test('表示文字列はサロゲートペアを分断せずに切り詰める', () {
    expect(sanitizeText('a\u0000b\n  c', maximumLength: 10), 'a b c');
    expect(sanitizeText('😀😀😀', maximumLength: 2), '😀😀');
  });

  test('URLはホスト名付きのHTTP(S)だけ', () {
    expect(parseHttpUri('https://example.com/a.m3u8'), isNotNull);
    expect(parseHttpUri('http:///nohost'), isNull);
    expect(parseHttpUri('file:///c:/x'), isNull);
  });

  test('技法は36種で、ビブラートは30へ集約', () {
    expect(displayedTechniqueIds, hasLength(36));
    expect(displayedTechniqueIds, contains(43));
    expect(canonicalTechniqueId(35), 30);
    expect(techniqueAsset(38), 'assets/scoring/technique_30.png');
    expect(techniqueName(99), '不明');
  });

  test('バージョン比較', () {
    expect(
      AppVersion.tryParse('v2.0.0')! > AppVersion.tryParse('1.10.99')!,
      isTrue,
    );
    expect(AppVersion.tryParse('1.2'), isNull);
    expect(AppVersion.tryParse('1.2.3-beta'), isNull);
  });

  test('リモコン値の検証', () {
    expect(isSongToken('abc_DEF-1'), isTrue);
    expect(isSongToken('a/b'), isFalse);
    expect(isQueueToken('q_c_3'), isTrue);
    expect(isQueueToken('q_x_3'), isFalse);
    expect(RemoteSearchMode.fromBrowser('new'), RemoteSearchMode.newReleases);
    expect(RemoteSearchMode.fromBrowser('history'), isNull);
    final state = RemoteControlState.fromJson(<String, Object?>{
      'connected': true,
      'key': 99,
      'confirmation': <String, Object?>{'message': 'ok?', 'selected': 'no'},
    });
    expect(state.key, maximumKey);
    expect(state.toJson()['confirmation'], <String, Object>{
      'message': 'ok?',
      'selected': 'no',
    });
  });
}
