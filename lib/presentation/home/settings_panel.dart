// Project: DAM for Windows Tools
// File: home/settings_panel.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/app_controller.dart';
import '../../domain/app_settings.dart';
import '../widgets/panel.dart';
import '../widgets/setting_checkbox.dart';

/// 4つの独立機能と、マイク遅延補正値を編集する設定パネルです。
class SettingsPanel extends StatefulWidget {
  /// 現在設定と更新操作を提供するコントローラーを受け取ります。
  const SettingsPanel({super.key, required this.controller});

  final AppController controller;

  /// 入力中の補正値と遅延更新タイマーを管理する状態を生成します。
  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

/// 数値入力中のカーソルを乱さず、確定値だけをコントローラーへ反映します。
class _SettingsPanelState extends State<SettingsPanel> {
  late final TextEditingController _skipController;
  late final FocusNode _skipFocusNode;
  Timer? _skipDebounce;

  /// 保存済み補正値を入力欄へ設定し、フォーカスと外部更新の監視を開始します。
  @override
  void initState() {
    super.initState();
    _skipController = TextEditingController(
      text: widget.controller.settings.skipMs.toString(),
    );
    _skipFocusNode = FocusNode()..addListener(_handleSkipFocus);
    widget.controller.addListener(_syncSkipText);
  }

  /// 保留中タイマーと監視を解除して、入力コントローラーを破棄します。
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

  /// 入力欄からフォーカスが外れた時点で、補正値を即時確定します。
  void _handleSkipFocus() {
    if (!_skipFocusNode.hasFocus) _commitSkip(_skipController.text);
  }

  /// 利用者が編集中でない場合だけ、外部で変わった設定値を入力欄へ同期します。
  void _syncSkipText() {
    if (_skipFocusNode.hasFocus) return;
    final value = widget.controller.settings.skipMs.toString();
    if (_skipController.text != value) _skipController.text = value;
  }

  /// 連続入力ごとの保存を避け、最後の変更から350ミリ秒後に確定します。
  void _scheduleSkipUpdate(String value) {
    _skipDebounce?.cancel();
    _skipDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _commitSkip(value),
    );
  }

  /// 数値を0～30000ミリ秒へ収め、変更がある場合だけ設定を更新します。
  void _commitSkip(String value) {
    _skipDebounce?.cancel();
    final parsed = int.tryParse(value);
    if (parsed == null) return;
    final normalized = parsed.clamp(
      AppSettings.minimumSkipMs,
      AppSettings.maximumSkipMs,
    );
    if (normalized != widget.controller.settings.skipMs) {
      _update(widget.controller.settings.copyWith(skipMs: normalized));
    }
    if (!_skipFocusNode.hasFocus &&
        _skipController.text != normalized.toString()) {
      _skipController.text = normalized.toString();
    }
  }

  /// GUIを待たせず、正規化と永続化をコントローラーへ委譲します。
  void _update(AppSettings settings) {
    unawaited(widget.controller.updateSettings(settings));
  }

  /// 横幅に応じて1列または2列へ切り替わる設定項目を構築します。
  @override
  Widget build(BuildContext context) {
    final settings = widget.controller.settings;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const PanelTitle('設定'),
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
                      child: SettingCheckbox(
                        label: 'モジュールチェック無効化',
                        description: 'DAMの拡張モジュール検出だけを無効化します。',
                        value: settings.disableModuleCheck,
                        onChanged: (value) => _update(
                          settings.copyWith(disableModuleCheck: value),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: itemWidth,
                      child: SettingCheckbox(
                        label: 'フォアグラウンドチェック無効化',
                        description: 'DAMが手前にない状態でも操作と再生を続けられるようにします。',
                        value: settings.disableForegroundCheck,
                        onChanged: (value) => _update(
                          settings.copyWith(disableForegroundCheck: value),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: itemWidth,
                      child: SettingCheckbox(
                        label: '動画URLを差し替え',
                        description: '動画をローカル中継へ切り替え、指定動画や遅延補正を適用します。',
                        value: settings.replaceVideoUrls,
                        onChanged: (value) =>
                            _update(settings.copyWith(replaceVideoUrls: value)),
                      ),
                    ),
                    SizedBox(
                      width: itemWidth,
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: SettingCheckbox(
                              label: '再生開始位置をスキップ（マイク遅延補正）',
                              description:
                                  '動画の先頭を指定ms分進め、マイク・採点とのタイミングのずれを調整します。',
                              value: settings.skipEnabled,
                              onChanged: (value) => _update(
                                settings.copyWith(skipEnabled: value),
                              ),
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
}
