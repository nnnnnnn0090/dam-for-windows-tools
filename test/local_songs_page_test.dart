import 'dart:io';

import 'package:dam_for_windows_tools/app/app_controller.dart';
import 'package:dam_for_windows_tools/app/states.dart';
import 'package:dam_for_windows_tools/domain/local_songs.dart';
import 'package:dam_for_windows_tools/infra/paths.dart';
import 'package:dam_for_windows_tools/ui/local_songs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ローカル曲の一覧・動画の状態・追加画面を表示する', (tester) async {
    final controller = AppController(
      paths: AppPaths(root: Directory.systemTemp.path, sessionId: 'test'),
    );
    controller.localSongs.value = const <LocalSong>[
      LocalSong(
        requestNo: '9999-01',
        title: 'where the light leads us',
        artist: 'fripSide',
        titleYomi: 'ホエアザライトリーズアス',
        artistYomi: 'フリップサイド',
        playtimeSeconds: 245,
        melody: <MelodyNote>[
          MelodyNote(10000, 10450, 71),
          MelodyNote(10500, 10950, 67),
        ],
      ),
      LocalSong(requestNo: '9999-02', title: 'no video', artist: 'X'),
    ];
    controller.manualVideos.value = const <String>{'9999-01'};
    controller.tasks.update(TaskKind.import, '9999-02', fraction: 0.5);
    tester.view
      ..physicalSize = const Size(1100, 700)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LocalSongsPage(controller: controller)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('ローカル曲 (2)'), findsOneWidget);
    expect(find.text('where the light leads us'), findsOneWidget);
    expect(find.text('4:05'), findsOneWidget);
    expect(find.text('登録済み'), findsOneWidget);
    expect(find.text('取り込み中 50%'), findsOneWidget);
    expect(find.text('あり（2音）'), findsOneWidget);
    expect(find.text('なし'), findsOneWidget);

    // 採点ダイアログ: MIDIを読み込むまでは取り込めず、採点データがあれば外せる
    await tester.tap(find.byKey(const Key('local-song-score-9999-01')));
    await tester.pumpAndSettle();
    expect(find.text('9999-01 の採点データ'), findsOneWidget);
    expect(find.text('現在: あり（2音）'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('local-song-score-save')))
          .onPressed,
      isNull,
    );
    expect(find.byKey(const Key('local-song-score-clear')), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('local-song-add')));
    await tester.pumpAndSettle();
    expect(find.text('ローカル曲を追加'), findsOneWidget);
    // 曲名・アーティスト名・動画がそろうまで追加できない
    final save = find.byKey(const Key('local-song-save'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('local-song-title')), 'a');
    await tester.enterText(find.byKey(const Key('local-song-artist')), 'b');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
  });
}
