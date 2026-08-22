// Project: DAM for Windows Tools
// File: home_page.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-22

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/app_controller.dart';
import '../config/app_config.dart';
import '../domain/models.dart';
import 'widgets/qr_code_view.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final TextEditingController _skipController;
  late final FocusNode _skipFocusNode;
  Timer? _skipDebounce;
  bool _showLogs = false;
  int _selectedPage = 0;

  @override
  void initState() {
    super.initState();
    _skipController = TextEditingController(
      text: widget.controller.settings.skipMs.toString(),
    );
    _skipFocusNode = FocusNode()..addListener(_handleSkipFocus);
    widget.controller.addListener(_syncSkipText);
  }

  @override
  void dispose() {
    _skipDebounce?.cancel();
    widget.controller.removeListener(_syncSkipText);
    _skipFocusNode
      ..removeListener(_handleSkipFocus)
      ..dispose();
    _skipController.dispose();
    super.dispose();
  }

  void _handleSkipFocus() {
    if (!_skipFocusNode.hasFocus) _commitSkip(_skipController.text);
  }

  void _syncSkipText() {
    if (_skipFocusNode.hasFocus) return;
    final value = widget.controller.settings.skipMs.toString();
    if (_skipController.text != value) _skipController.text = value;
  }

  void _scheduleSkipUpdate(String value) {
    _skipDebounce?.cancel();
    _skipDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _commitSkip(value),
    );
  }

  void _commitSkip(String value) {
    _skipDebounce?.cancel();
    final parsed = int.tryParse(value);
    if (parsed == null) return;
    final normalized = parsed.clamp(0, 30000);
    if (normalized != widget.controller.settings.skipMs) {
      unawaited(
        widget.controller.updateSettings(
          widget.controller.settings.copyWith(skipMs: normalized),
        ),
      );
    }
    if (!_skipFocusNode.hasFocus &&
        _skipController.text != normalized.toString()) {
      _skipController.text = normalized.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return Scaffold(
          appBar: _buildAppBar(controller),
          body: controller.fatalError == null
              ? _buildWorkspace(controller)
              : _buildFatalError(controller.fatalError!),
        );
      },
    );
  }

  Widget _buildWorkspace(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          height: 40,
          decoration: const BoxDecoration(
            color: Color(0xff15181d),
            border: Border(bottom: BorderSide(color: Color(0xff333840))),
          ),
          child: Row(
            children: <Widget>[
              const SizedBox(width: 8),
              _PageTab(
                label: '動画',
                selected: _selectedPage == 0,
                onTap: () => setState(() => _selectedPage = 0),
              ),
              _PageTab(
                label: '採点',
                selected: _selectedPage == 1,
                onTap: () => setState(() => _selectedPage = 1),
              ),
            ],
          ),
        ),
        Expanded(
          child: _selectedPage == 0
              ? _buildContent(controller)
              : _buildScoringContent(controller),
        ),
      ],
    );
  }

  PreferredSizeWidget _buildAppBar(AppController controller) {
    final statusColor = _connectionColor(controller.connectionCode);
    return AppBar(
      toolbarHeight: 52,
      titleSpacing: 16,
      title: const Text(
        AppConfig.productName,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      actions: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Text(
            controller.connectionState,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Color(0xffc6cbd2)),
          ),
        ),
        const SizedBox(width: 12),
        TextButton.icon(
          key: const Key('licenses-button'),
          onPressed: () => showLicensePage(
            context: context,
            applicationName: AppConfig.productName,
            applicationLegalese:
                'Copyright (c) 2026 nnnnnnn0090\n'
                'GPL-3.0-or-later\n\n'
                '${AppConfig.legalSummary}\n\n'
                'リモコンは信頼できる家庭内LAN専用です。',
          ),
          icon: const Icon(Icons.info_outline, size: 17),
          label: const Text('ライセンス'),
        ),
        const SizedBox(width: 4),
        TextButton.icon(
          key: const Key('remote-control-button'),
          onPressed: controller.remoteControlUrl == null
              ? null
              : () => _showRemoteControlDialog(controller),
          icon: const Icon(Icons.qr_code_2, size: 17),
          label: const Text('リモコン'),
        ),
        const SizedBox(width: 4),
        TextButton(
          onPressed: controller.initialized ? controller.reconnect : null,
          child: const Text('再接続'),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildContent(AppController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildSettings(controller),
          const SizedBox(height: 12),
          Expanded(child: _buildHistory(controller)),
          const SizedBox(height: 4),
          _buildLogArea(controller),
        ],
      ),
    );
  }

  Widget _buildScoringContent(AppController controller) {
    final settings = controller.settings;
    final counts = canonicalScoringTechniqueIds
        .map(
          (techniqueId) => MapEntry<int, int>(
            techniqueId,
            controller.scoringCounts[techniqueId] ?? 0,
          ),
        )
        .toList(growable: false);
    final total = counts.fold<int>(0, (sum, entry) => sum + entry.value);
    final last = controller.lastScoringEvent;
    void update(AppSettings next) => unawaited(controller.updateSettings(next));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Panel(
            child: SizedBox(
              height: 68,
              child: Row(
                children: <Widget>[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 330,
                    child: _SettingCheckbox(
                      label: '採点表示',
                      description: 'しゃくり・ビブラートなどの検知結果を表示します。DAM本体の採点設定とは別です。',
                      value: settings.scoringEnabled,
                      onChanged: (value) =>
                          update(settings.copyWith(scoringEnabled: value)),
                    ),
                  ),
                  const VerticalDivider(),
                  const SizedBox(width: 12),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: controller.scoringActive
                          ? const Color(0xff4fb477)
                          : const Color(0xff8d939c),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    controller.scoringActive ? '採点中' : '採点待機中',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  if (last != null) ...<Widget>[
                    const SizedBox(width: 24),
                    const Text(
                      '直近',
                      style: TextStyle(fontSize: 11, color: Color(0xff9298a1)),
                    ),
                    const SizedBox(width: 8),
                    Text(last.name, style: const TextStyle(fontSize: 12.5)),
                  ],
                  const Spacer(),
                  TextButton(
                    onPressed: total == 0
                        ? null
                        : controller.clearScoringSession,
                    child: const Text('リセット'),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    height: 43,
                    child: Row(
                      children: <Widget>[
                        const Padding(
                          padding: EdgeInsets.only(left: 14),
                          child: Text(
                            '歌唱表現',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '合計 $total 回',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xffa5abb4),
                          ),
                        ),
                        const SizedBox(width: 14),
                      ],
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: _ScoringGrid(
                      counts: counts,
                      latestTechniqueId: last == null
                          ? null
                          : canonicalScoringTechniqueId(last.techniqueId),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettings(AppController controller) {
    final settings = controller.settings;
    void update(AppSettings next) => unawaited(controller.updateSettings(next));
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _PanelTitle('設定'),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const gap = 12.0;
                final useTwoColumns = constraints.maxWidth >= 760;
                final itemWidth = useTwoColumns
                    ? (constraints.maxWidth - gap) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: gap,
                  runSpacing: 4,
                  children: <Widget>[
                    SizedBox(
                      width: itemWidth,
                      child: _SettingCheckbox(
                        label: 'モジュールチェック無効化',
                        description: 'DAMの拡張モジュール検出だけを無効化します。',
                        value: settings.disableModuleCheck,
                        onChanged: (value) => update(
                          settings.copyWith(disableModuleCheck: value),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: itemWidth,
                      child: _SettingCheckbox(
                        label: 'フォアグラウンドチェック無効化',
                        description: 'DAMが手前にない状態でも操作と再生を続けられるようにします。',
                        value: settings.disableForegroundCheck,
                        onChanged: (value) => update(
                          settings.copyWith(disableForegroundCheck: value),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: itemWidth,
                      child: _SettingCheckbox(
                        label: '動画URLを差し替え',
                        description: '動画をローカル中継へ切り替え、指定動画や遅延補正を適用します。',
                        value: settings.replaceVideoUrls,
                        onChanged: (value) =>
                            update(settings.copyWith(replaceVideoUrls: value)),
                      ),
                    ),
                    SizedBox(
                      width: itemWidth,
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: _SettingCheckbox(
                              label: '再生開始位置をスキップ（マイク遅延補正）',
                              description:
                                  '動画の先頭を指定ms分進め、マイク・採点とのタイミングのずれを調整します。',
                              value: settings.skipEnabled,
                              onChanged: (value) =>
                                  update(settings.copyWith(skipEnabled: value)),
                            ),
                          ),
                          SizedBox(
                            width: 92,
                            height: 34,
                            child: TextField(
                              key: const Key('skip-ms-field'),
                              controller: _skipController,
                              focusNode: _skipFocusNode,
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
                              onChanged: _scheduleSkipUpdate,
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
        ],
      ),
    );
  }

  Future<void> _showRemoteControlDialog(AppController controller) async {
    final url = controller.remoteControlUrl;
    if (url == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('remote-control-dialog'),
        title: const Text('リモコン'),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                'スマホをこのPCと同じWi-Fiに接続して、QRコードを読み取ってください。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: 8),
              const Text(
                '信頼できる家庭内Wi-Fi専用です。公共・来客用Wi-Fiでは使用しないでください。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Color(0xffffc66d)),
              ),
              const SizedBox(height: 16),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(10),
                child: QrCodeView(
                  key: const Key('remote-control-qr'),
                  data: url,
                  size: 225,
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('閉じる'),
          ),
          FilledButton.icon(
            key: const Key('remote-control-open-browser'),
            onPressed: controller.openRemoteControl,
            icon: const Icon(Icons.open_in_new, size: 17),
            label: const Text('ブラウザで開く'),
          ),
        ],
      ),
    );
  }

  Widget _buildHistory(AppController controller) {
    final tracks = controller.tracks;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: 43,
            child: Row(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Text(
                    '再生履歴 (${tracks.length})',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: tracks.isEmpty
                      ? null
                      : () => _confirmClearHistory(context, controller),
                  child: const Text('履歴消去'),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: tracks.isEmpty
                ? const Center(
                    child: Text(
                      '再生履歴はありません',
                      style: TextStyle(color: Color(0xff888e98)),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      return constraints.maxWidth >= 760
                          ? _DesktopHistory(
                              tracks: tracks,
                              controller: controller,
                              onChoose: (videoId) =>
                                  _chooseVideo(controller, videoId),
                            )
                          : _CompactHistory(
                              tracks: tracks,
                              controller: controller,
                              onChoose: (videoId) =>
                                  _chooseVideo(controller, videoId),
                            );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogArea(AppController controller) {
    final text = controller.logs.isEmpty
        ? 'ログはありません'
        : controller.logs.reversed.take(120).toList().reversed.join('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => setState(() => _showLogs = !_showLogs),
            child: Text(_showLogs ? '診断ログを閉じる' : '診断ログ'),
          ),
        ),
        if (_showLogs)
          _Panel(
            child: SizedBox(
              height: 150,
              child: Column(
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
                          onPressed: controller.logs.isEmpty
                              ? null
                              : () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: text),
                                  );
                                },
                          child: const Text('コピー'),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: SingleChildScrollView(
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
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFatalError(String error) {
    return Center(
      child: _Panel(
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

  Future<void> _chooseVideo(AppController controller, String videoId) async {
    try {
      await controller.chooseManualVideo(videoId);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _confirmClearHistory(
    BuildContext context,
    AppController controller,
  ) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('再生履歴を消去'),
        content: const Text('動画ID・アーティスト名・曲名の履歴を消去します。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('消去'),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.clearHistory();
  }
}

Color _connectionColor(String state) {
  switch (state) {
    case 'attached':
      return const Color(0xff4fb477);
    case 'unsupported':
    case 'attach-error':
    case 'helper-exited':
    case 'failed':
      return const Color(0xffd96767);
    case 'attaching':
      return const Color(0xff5b9bd5);
    default:
      return const Color(0xffc59a46);
  }
}

class _PageTab extends StatelessWidget {
  const _PageTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('page-tab-$label'),
      onTap: onTap,
      child: Container(
        width: 82,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? const Color(0xff4e91cb) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            color: selected ? const Color(0xffe0e3e8) : const Color(0xff9298a1),
          ),
        ),
      ),
    );
  }
}

class _ScoringGrid extends StatelessWidget {
  const _ScoringGrid({required this.counts, required this.latestTechniqueId});

  final List<MapEntry<int, int>> counts;
  final int? latestTechniqueId;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      key: const Key('scoring-technique-grid'),
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisExtent: 84,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: counts.length,
      itemBuilder: (context, index) {
        final entry = counts[index];
        return _ScoringTile(
          techniqueId: entry.key,
          count: entry.value,
          latest: entry.key == latestTechniqueId,
        );
      },
    );
  }
}

class _ScoringTile extends StatelessWidget {
  const _ScoringTile({
    required this.techniqueId,
    required this.count,
    required this.latest,
  });

  final int techniqueId;
  final int count;
  final bool latest;

  @override
  Widget build(BuildContext context) {
    final name = scoringTechniqueName(techniqueId);
    final detected = count > 0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: latest ? const Color(0xff1b2731) : const Color(0xff191c21),
        border: Border.all(
          color: latest ? const Color(0xff4e91cb) : const Color(0xff30353d),
        ),
        borderRadius: BorderRadius.circular(3),
      ),
      padding: const EdgeInsets.fromLTRB(7, 7, 8, 7),
      child: Row(
        children: <Widget>[
          AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: detected ? 1 : 0.28,
            child: SizedBox(
              width: 52,
              child: Semantics(
                label: '$nameのアイコン',
                image: true,
                child: Image.asset(
                  scoringTechniqueAsset(techniqueId),
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: detected
                            ? const Color(0xffd5d8dd)
                            : const Color(0xff8b919a),
                        fontSize: 11,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
                Text(
                  '×$count',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: latest
                        ? const Color(0xff79b6e7)
                        : detected
                        ? const Color(0xffd6d9de)
                        : const Color(0xff777d86),
                    fontFamily: 'Consolas',
                    fontSize: 13.5,
                    height: 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xff171a1f),
        border: Border.all(color: const Color(0xff333840)),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 10),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _SettingCheckbox extends StatelessWidget {
  const _SettingCheckbox({
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Checkbox(
            value: value,
            onChanged: (next) => onChanged(next ?? false),
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.5,
                      height: 1.25,
                      color: Color(0xff9298a1),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopHistory extends StatelessWidget {
  const _DesktopHistory({
    required this.tracks,
    required this.controller,
    required this.onChoose,
  });

  final List<TrackView> tracks;
  final AppController controller;
  final ValueChanged<String> onChoose;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const _HistoryColumns(),
        Expanded(
          child: ListView.builder(
            itemCount: tracks.length,
            itemExtent: 46,
            itemBuilder: (context, index) {
              final track = tracks[index];
              final id = track.record.videoId;
              return _HistoryRow(
                track: track,
                manual: controller.hasManualVideo(id),
                onChoose: () => onChoose(id),
                onClear: () => unawaited(controller.clearManualVideo(id)),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HistoryColumns extends StatelessWidget {
  const _HistoryColumns();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: const Color(0xff1d2026),
      child: const Row(
        children: <Widget>[
          Expanded(flex: 17, child: _ColumnLabel('動画ID')),
          Expanded(flex: 24, child: _ColumnLabel('アーティスト')),
          Expanded(flex: 29, child: _ColumnLabel('曲名')),
          Expanded(flex: 13, child: _ColumnLabel('状態')),
          Expanded(flex: 17, child: _ColumnLabel('差し替え動画')),
        ],
      ),
    );
  }
}

class _ColumnLabel extends StatelessWidget {
  const _ColumnLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 11, color: Color(0xff9ca2ac)),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.track,
    required this.manual,
    required this.onChoose,
    required this.onClear,
  });

  final TrackView track;
  final bool manual;
  final VoidCallback onChoose;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final record = track.record;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xff292d34))),
      ),
      child: Row(
        children: <Widget>[
          Expanded(flex: 17, child: _Cell(record.videoId, monospace: true)),
          Expanded(flex: 24, child: _Cell(record.artist)),
          Expanded(flex: 29, child: _Cell(record.title)),
          Expanded(flex: 13, child: _StageText(track.stage)),
          Expanded(
            flex: 17,
            child: _VideoButtons(
              manual: manual,
              onChoose: onChoose,
              onClear: onClear,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactHistory extends StatelessWidget {
  const _CompactHistory({
    required this.tracks,
    required this.controller,
    required this.onChoose,
  });

  final List<TrackView> tracks;
  final AppController controller;
  final ValueChanged<String> onChoose;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: tracks.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, index) {
        final track = tracks[index];
        final id = track.record.videoId;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: <Widget>[
              SizedBox(width: 92, child: _Cell(id, monospace: true)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _Cell(track.record.title),
                    const SizedBox(height: 2),
                    _Cell(track.record.artist, secondary: true),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StageText(track.stage),
              const SizedBox(width: 8),
              _VideoButtons(
                manual: controller.hasManualVideo(id),
                onChoose: () => onChoose(id),
                onClear: () => unawaited(controller.clearManualVideo(id)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell(this.value, {this.monospace = false, this.secondary = false});

  final String value;
  final bool monospace;
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Text(
        value.isEmpty ? '—' : value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: monospace ? 'Consolas' : null,
          fontSize: secondary ? 11 : 12.5,
          color: secondary ? const Color(0xff8e949e) : const Color(0xffd4d7dc),
        ),
      ),
    );
  }
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
      PlaybackStage.rewritten => const Color(0xff65a5dc),
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

class _VideoButtons extends StatelessWidget {
  const _VideoButtons({
    required this.manual,
    required this.onChoose,
    required this.onClear,
  });

  final bool manual;
  final VoidCallback onChoose;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TextButton(
          onPressed: onChoose,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: Text(manual ? '変更...' : '選択...'),
        ),
        if (manual)
          TextButton(
            onPressed: onClear,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            child: const Text('解除'),
          ),
      ],
    );
  }
}
