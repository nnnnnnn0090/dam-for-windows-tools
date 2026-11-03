import 'dart:io';

import 'package:dam_for_windows_tools/app/app_controller.dart';
import 'package:dam_for_windows_tools/app/states.dart';
import 'package:dam_for_windows_tools/infra/paths.dart';
import 'package:dam_for_windows_tools/ui/video_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('作業中の一覧と再生履歴の行に、進み具合を出す', (tester) async {
    final controller = AppController(
      paths: AppPaths(root: Directory.systemTemp.path, sessionId: 'test'),
    );
    controller.history.registerPlayback('6343-36');
    controller.history.registerPlayback('1-1');
    controller.tasks
      ..update(
        TaskKind.transcode,
        '6343-36',
        fraction: 0.42,
        detail: '1:23 / 4:40',
      )
      ..update(
        TaskKind.import,
        '1-1',
        fraction: 0.1,
        detail: '10.0MB / 100.0MB',
      );
    addTearDown(tester.view.reset);

    // 狭い画面（縦に並べる表示）と広い画面（表の表示）の両方で確かめる
    for (final width in <double>[600, 1200]) {
      tester.view
        ..physicalSize = Size(width, 800)
        ..devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                TaskBanner(controller: controller),
                Expanded(child: HistoryPanel(controller: controller)),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: '幅 $width で描画エラー');
      expect(find.text('作業中 (2)'), findsOneWidget);
      expect(find.text('変換中 42%'), findsOneWidget);
      expect(find.text('取り込み中 10%'), findsOneWidget);
      expect(find.textContaining('1:23 / 4:40'), findsOneWidget);
      // 取り込み中の曲は、選択ボタンが押せない「取り込み中」になる
      expect(find.widgetWithText(TextButton, '取り込み中'), findsOneWidget);
    }

    // 作業が終われば一覧は消え、行は再生の状態に戻る
    controller.tasks
      ..end(TaskKind.transcode, '6343-36')
      ..end(TaskKind.import, '1-1');
    await tester.pump();
    expect(find.textContaining('作業中'), findsNothing);
    expect(find.text('変換中 42%'), findsNothing);
  });
}
