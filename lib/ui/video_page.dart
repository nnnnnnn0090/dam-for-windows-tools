import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../domain/settings.dart';
import '../domain/tracks.dart';
import 'theme.dart';
import 'widgets.dart';

/// 「動画」タブです。設定・再生履歴・診断ログを縦に並べます。
class VideoPage extends StatelessWidget {
  const VideoPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SettingsPanel(controller: controller),
        const SizedBox(height: 12),
        Expanded(child: HistoryPanel(controller: controller)),
        const SizedBox(height: 4),
        DiagnosticLogPanel(controller: controller),
      ],
    ),
  );
}

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late final TextEditingController _skip = TextEditingController(
    text: '${_settings.skipMs}',
  );
  late final FocusNode _skipFocus = FocusNode()..addListener(_onSkipFocus);
  Timer? _skipDebounce;

  AppSettings get _settings => widget.controller.settings.value;

  @override
  void initState() {
    super.initState();
    widget.controller.settings.addListener(_syncSkipText);
  }

  @override
  void dispose() {
    _skipDebounce?.cancel();
    widget.controller.settings.removeListener(_syncSkipText);
    _skipFocus.dispose();
    _skip.dispose();
    super.dispose();
  }

  void _onSkipFocus() {
    if (!_skipFocus.hasFocus) _commitSkip(_skip.text);
  }

  void _syncSkipText() {
    if (!_skipFocus.hasFocus && _skip.text != '${_settings.skipMs}') {
      _skip.text = '${_settings.skipMs}';
    }
  }

  void _commitSkip(String text) {
    _skipDebounce?.cancel();
    final parsed = int.tryParse(text);
    if (parsed == null) return;
    _update(_settings.copyWith(skipMs: parsed));
    if (!_skipFocus.hasFocus) _syncSkipText();
  }

  void _update(AppSettings next) =>
      unawaited(widget.controller.updateSettings(next));

  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const PanelHeader('設定'),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
          child: ValueListenableBuilder<AppSettings>(
            valueListenable: widget.controller.settings,
            builder: (context, settings, _) => LayoutBuilder(
              builder: (context, constraints) {
                const gap = 12.0;
                final width = constraints.maxWidth >= 760
                    ? (constraints.maxWidth - gap) / 2
                    : constraints.maxWidth;
                Widget item(Widget child) =>
                    SizedBox(width: width, child: child);
                return Wrap(
                  spacing: gap,
                  runSpacing: 4,
                  children: <Widget>[
                    item(
                      SettingCheckbox(
                        label: 'モジュールチェック無効化',
                        description: 'DAMの拡張モジュール検出だけを無効化します。',
                        value: settings.disableModuleCheck,
                        onChanged: (v) =>
                            _update(settings.copyWith(disableModuleCheck: v)),
                      ),
                    ),
                    item(
                      SettingCheckbox(
                        label: 'フォアグラウンドチェック無効化',
                        description: 'DAMが手前にない状態でも操作と再生を続けられるようにします。',
                        value: settings.disableForegroundCheck,
                        onChanged: (v) => _update(
                          settings.copyWith(disableForegroundCheck: v),
                        ),
                      ),
                    ),
                    item(
                      SettingCheckbox(
                        label: '動画URLを差し替え',
                        description: '動画をローカル中継へ切り替え、指定動画や遅延補正を適用します。',
                        value: settings.replaceVideoUrls,
                        onChanged: (v) =>
                            _update(settings.copyWith(replaceVideoUrls: v)),
                      ),
                    ),
                    item(
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: SettingCheckbox(
                              label: '再生開始位置をスキップ（マイク遅延補正）',
                              description:
                                  '動画の先頭を指定ms分進め、マイク・採点とのタイミングのずれを調整します。',
                              value: settings.skipEnabled,
                              onChanged: (v) =>
                                  _update(settings.copyWith(skipEnabled: v)),
                            ),
                          ),
                          SizedBox(
                            width: 92,
                            height: 34,
                            child: TextField(
                              key: const Key('skip-ms-field'),
                              controller: _skip,
                              focusNode: _skipFocus,
                              enabled: settings.skipEnabled,
                              textAlign: TextAlign.right,
                              keyboardType: TextInputType.number,
                              inputFormatters: <TextInputFormatter>[
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(5),
                              ],
                              decoration: const InputDecoration(
                                suffixText: 'ms',
                                isDense: true,
                              ),
                              onChanged: (text) {
                                _skipDebounce?.cancel();
                                _skipDebounce = Timer(
                                  const Duration(milliseconds: 350),
                                  () => _commitSkip(text),
                                );
                              },
                              onSubmitted: _commitSkip,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    ),
  );
}

class HistoryPanel extends StatelessWidget {
  const HistoryPanel({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => Panel(
    child: ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller.history,
        controller.manualVideos,
        controller.exportUnlocked,
        controller.exportableVideos,
        controller.exportingVideos,
      ]),
      builder: (context, _) {
        final records = controller.history.records;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            PanelHeader(
              '再生履歴 (${records.length})',
              trailing: <Widget>[
                TextButton(
                  onPressed: records.isEmpty
                      ? null
                      : () => unawaited(_confirmClear(context)),
                  child: const Text('履歴消去'),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: records.isEmpty
                  ? const Center(
                      child: Text(
                        '再生履歴はありません',
                        style: TextStyle(color: AppColors.textFaint),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) =>
                          constraints.maxWidth >= 760
                          ? _wideList(context, records)
                          : _compactList(context, records),
                    ),
            ),
          ],
        );
      },
    ),
  );

  Widget _wideList(BuildContext context, List<TrackRecord> records) => Column(
    children: <Widget>[
      Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: AppColors.tableHeader,
        child: const Row(
          children: <Widget>[
            Expanded(flex: 15, child: _ColumnLabel('動画ID')),
            Expanded(flex: 21, child: _ColumnLabel('アーティスト')),
            Expanded(flex: 25, child: _ColumnLabel('曲名')),
            Expanded(flex: 12, child: _ColumnLabel('状態')),
            Expanded(flex: 27, child: _ColumnLabel('差し替え動画')),
          ],
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: records.length,
          itemExtent: 46,
          itemBuilder: (context, index) {
            final record = records[index];
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.rowBorder)),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    flex: 15,
                    child: _Cell(record.videoId, monospace: true),
                  ),
                  Expanded(flex: 21, child: _Cell(record.artist)),
                  Expanded(flex: 25, child: _Cell(record.title)),
                  Expanded(
                    flex: 12,
                    child: _StageText(
                      controller.history.stageOf(record.videoId),
                    ),
                  ),
                  Expanded(flex: 27, child: _videoButtons(context, record)),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );

  Widget _compactList(BuildContext context, List<TrackRecord> records) =>
      ListView.separated(
        itemCount: records.length,
        separatorBuilder: (_, _) => const Divider(),
        itemBuilder: (context, index) {
          final record = records[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 92,
                  child: _Cell(record.videoId, monospace: true),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _Cell(record.title),
                      const SizedBox(height: 2),
                      _Cell(record.artist, secondary: true),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _StageText(controller.history.stageOf(record.videoId)),
                const SizedBox(width: 8),
                _videoButtons(context, record),
              ],
            ),
          );
        },
      );

  Widget _videoButtons(BuildContext context, TrackRecord record) {
    final videoId = record.videoId;
    final manual = controller.manualVideos.value.contains(videoId);
    final exportable = controller.exportableVideos.value.contains(videoId);
    final exporting = controller.exportingVideos.value.contains(videoId);
    final style = TextButton.styleFrom(
      minimumSize: const Size(0, 30),
      padding: const EdgeInsets.symmetric(horizontal: 8),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TextButton(
          style: style,
          onPressed: () => unawaited(_choose(context, videoId)),
          child: Text(manual ? '変更...' : '選択...'),
        ),
        if (manual)
          TextButton(
            style: style,
            onPressed: () => unawaited(controller.clearManualVideo(videoId)),
            child: const Text('解除'),
          ),
        if (controller.exportUnlocked.value)
          Tooltip(
            message: exportable
                ? 'DAMの公式動画をMP4で保存します（差し替え動画のタイミング合わせ用）'
                : 'DAMで再生すると書き出せます（今回の起動中に再生した曲のみ）',
            child: TextButton(
              style: style,
              onPressed: exportable && !exporting
                  ? () => unawaited(_export(context, record))
                  : null,
              child: Text(exporting ? '書き出し中' : '書き出し...'),
            ),
          ),
      ],
    );
  }

  Future<void> _export(BuildContext context, TrackRecord record) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await controller.exportOriginalVideo(record);
      if (path == null) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('書き出しました: $path'),
          action: SnackBarAction(
            label: 'フォルダを開く',
            onPressed: () => unawaited(controller.revealFile(path)),
          ),
        ),
      );
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _choose(BuildContext context, String videoId) async {
    try {
      await controller.chooseManualVideo(videoId);
    } on Object catch (error) {
      controller.log.add('[$videoId] 差し替え動画を設定できません: $error');
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _confirmClear(BuildContext context) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('再生履歴を消去'),
        content: const Text('動画ID・アーティスト名・曲名の履歴を消去します。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('消去'),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.clearHistory();
  }
}

class _ColumnLabel extends StatelessWidget {
  const _ColumnLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(fontSize: 11, color: Color(0xff9ca2ac)),
  );
}

class _Cell extends StatelessWidget {
  const _Cell(this.value, {this.monospace = false, this.secondary = false});

  final String value;
  final bool monospace;
  final bool secondary;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 10),
    child: Text(
      value.isEmpty ? '—' : value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: monospace ? 'Consolas' : null,
        fontSize: secondary ? 11 : 12.5,
        color: secondary ? const Color(0xff8e949e) : AppColors.text,
      ),
    ),
  );
}

class _StageText extends StatelessWidget {
  const _StageText(this.stage);

  final PlaybackStage? stage;

  @override
  Widget build(BuildContext context) {
    final color = switch (stage) {
      PlaybackStage.streaming => const Color(0xff57b979),
      PlaybackStage.officialFallback => const Color(0xffd4a84f),
      PlaybackStage.failed => const Color(0xffdc6c6c),
      PlaybackStage.preparing ||
      PlaybackStage.manifestRequested ||
      PlaybackStage.rewritten => AppColors.info,
      _ => const Color(0xffa1a6ae),
    };
    return Text(
      stage?.label ?? '履歴',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: color),
    );
  }
}

class DiagnosticLogPanel extends StatefulWidget {
  const DiagnosticLogPanel({super.key, required this.controller});

  final AppController controller;

  @override
  State<DiagnosticLogPanel> createState() => _DiagnosticLogPanelState();
}

class _DiagnosticLogPanelState extends State<DiagnosticLogPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () => setState(() => _expanded = !_expanded),
          child: Text(_expanded ? '診断ログを閉じる' : '診断ログ'),
        ),
      ),
      if (_expanded)
        Panel(
          child: SizedBox(
            height: 150,
            child: ListenableBuilder(
              listenable: widget.controller.log,
              builder: (context, _) {
                final entries = widget.controller.log.entries;
                final text = entries.isEmpty
                    ? 'ログはありません'
                    : entries
                          .skip(entries.length > 120 ? entries.length - 120 : 0)
                          .join('\n');
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(
                      height: 38,
                      child: Row(
                        children: <Widget>[
                          const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Text(
                              '診断ログ',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: entries.isEmpty
                                ? null
                                : () => unawaited(
                                    Clipboard.setData(
                                      ClipboardData(text: entries.join('\n')),
                                    ),
                                  ),
                            child: const Text('コピー'),
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                    const Divider(),
                    Expanded(
                      child: SingleChildScrollView(
                        reverse: true,
                        padding: const EdgeInsets.all(10),
                        child: SelectableText(
                          text,
                          style: const TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 11,
                            height: 1.35,
                            color: Color(0xffb7bcc4),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
    ],
  );
}
