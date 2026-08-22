// Project: DAM for Windows Tools
// File: home/scoring_page.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/app_controller.dart';
import '../../domain/scoring.dart';
import '../widgets/panel.dart';
import '../widgets/setting_checkbox.dart';
import 'scoring_grid.dart';

class ScoringPage extends StatelessWidget {
  const ScoringPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Panel(
            child: SizedBox(
              height: 68,
              child: Row(
                children: <Widget>[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 330,
                    child: SettingCheckbox(
                      label: '採点表示',
                      description: 'しゃくり・ビブラートなどの検知結果を表示します。DAM本体の採点設定とは別です。',
                      value: settings.scoringEnabled,
                      onChanged: (value) => unawaited(
                        controller.updateSettings(
                          settings.copyWith(scoringEnabled: value),
                        ),
                      ),
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
            child: Panel(
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
                    child: ScoringGrid(
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
}
