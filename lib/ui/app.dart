import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../app/states.dart';
import '../app_config.dart';
import 'header.dart';
import 'scoring_page.dart';
import 'theme.dart';
import 'video_page.dart';
import 'widgets.dart';

class DamToolsApp extends StatefulWidget {
  const DamToolsApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<DamToolsApp> createState() => _DamToolsAppState();
}

class _DamToolsAppState extends State<DamToolsApp> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();
  final KeySequence _exportKeys = KeySequence(count: 10);

  AppController get controller => widget.controller;

  /// 「0」キー10連打で書き出しを表示します。入力欄への入力は妨げません。
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    final zero =
        key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0;
    if (_exportKeys.press(matches: zero, at: DateTime.now())) {
      controller.unlockExport();
    }
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    // ×ボタン・ログオフ時はrunnerから通知され、停止完了後にウィンドウを閉じます。
    controller.bridge.listen(onClose: controller.shutdown);
    unawaited(_start());
  }

  Future<void> _start() async {
    await controller.initialize();
    if (!controller.updatesSupported || controller.fatalError.value != null) {
      return;
    }
    await controller.checkForUpdates();
    final context = _navigator.currentContext;
    if (context != null &&
        context.mounted &&
        controller.update.available != null) {
      await showUpdatePrompt(context, controller);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigator,
    title: AppConfig.productName,
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.dark,
    darkTheme: AppTheme.dark,
    home: HomePage(controller: controller),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _page = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppHeader(controller: widget.controller),
    body: ValueListenableBuilder<String?>(
      valueListenable: widget.controller.fatalError,
      builder: (context, error, _) => error != null
          ? _FatalError(error)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  height: 40,
                  decoration: const BoxDecoration(
                    color: AppColors.tabBar,
                    border: Border(bottom: BorderSide(color: AppColors.border)),
                  ),
                  child: Row(
                    children: <Widget>[
                      const SizedBox(width: 8),
                      for (final (index, label) in const <String>[
                        '動画',
                        '採点',
                      ].indexed)
                        _Tab(
                          label: label,
                          selected: _page == index,
                          onTap: () => setState(() => _page = index),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: IndexedStack(
                    index: _page,
                    children: <Widget>[
                      VideoPage(controller: widget.controller),
                      ScoringPage(controller: widget.controller),
                    ],
                  ),
                ),
              ],
            ),
    ),
  );
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    key: Key('page-tab-$label'),
    onTap: onTap,
    child: Container(
      width: 82,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: selected ? AppColors.tabIndicator : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          color: selected ? AppColors.textStrong : AppColors.textMuted,
        ),
      ),
    ),
  );
}

class _FatalError extends StatelessWidget {
  const _FatalError(this.error);

  final String error;

  @override
  Widget build(BuildContext context) => Center(
    child: Panel(
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '起動できませんでした',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            SelectableText(
              error,
              style: const TextStyle(color: Color(0xffc7a5a9)),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Flutter標準のライセンス画面へ、本体と同梱物の通知文を登録します。
void registerLicenses() {
  void add(List<String> packages, List<String> assets) {
    LicenseRegistry.addLicense(() async* {
      final texts = await Future.wait(assets.map(rootBundle.loadString));
      yield LicenseEntryWithLineBreaks(packages, texts.join('\n\n'));
    });
  }

  add(const <String>['DAM for Windows Tools'], const <String>['LICENSE']);
  add(
    const <String>['FFmpeg 9.0.1 (Gyan full build)'],
    const <String>['legal/FFmpeg-GPL-3.0.txt'],
  );
  add(
    const <String>['Frida'],
    const <String>[
      'legal/Frida-LGPL-2.0.txt',
      'legal/WxWindows-exception-3.1.txt',
    ],
  );
  add(
    const <String>['QRCode for JavaScript algorithm'],
    const <String>['legal/QR-Code-generator-MIT.txt'],
  );
  add(const <String>['Lucide Icons'], const <String>['legal/Lucide-ISC.txt']);
  add(
    const <String>['Microsoft Visual C++ Runtime'],
    const <String>['legal/Microsoft-Visual-Cpp-Runtime.txt'],
  );
  add(
    const <String>['DAM for Windows Tools — third-party notices'],
    const <String>['THIRD_PARTY_NOTICES.md'],
  );
  add(
    const <String>['DAM for Windows Tools — 非公式ツールに関する表示'],
    const <String>['LEGAL_NOTICE.md'],
  );
}
