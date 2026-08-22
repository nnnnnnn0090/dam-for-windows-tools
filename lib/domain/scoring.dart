// Project: DAM for Windows Tools
// File: scoring.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

const List<String> scoringTechniqueNames = <String>[
  'しゃくり',
  '大しゃくり',
  '早いしゃくり',
  '早いしゃくり（強）',
  'L字アクセント',
  'L字アクセント（強）',
  'V字アクセント',
  'V字アクセント（カット）',
  'V字アクセント（下）',
  '逆V字アクセント',
  '先頭こぶし',
  'こぶし',
  'フライダウン',
  'ハンマリング・オン',
  'プリング・オフ',
  '上昇ポルタメント',
  '下降ポルタメント',
  '上昇スロープ',
  'フォール',
  '早いフォール',
  'ヒーカップ',
  'フォール付きヒーカップ',
  'スローダウン',
  'スライダー',
  '水平',
  'スタッカート',
  'U字',
  '逆U字',
  'への字',
  'アーチ',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ビブラート',
  'ジャストヒット',
  'エッジボイス',
  'フォールエッジ',
  '逆こぶし',
  '歌い回しなし',
];

const List<int> canonicalScoringTechniqueIds = <int>[
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  39,
  40,
  41,
  42,
  43,
];

int canonicalScoringTechniqueId(int id) => id >= 30 && id <= 38 ? 30 : id;

String scoringTechniqueName(int id) {
  if (id < 0 || id >= scoringTechniqueNames.length) return '不明';
  return scoringTechniqueNames[id];
}

String scoringTechniqueAsset(int id) {
  final canonical = canonicalScoringTechniqueId(id);
  return 'assets/scoring/technique_${canonical.toString().padLeft(2, '0')}.png';
}

class ScoringEvent {
  const ScoringEvent({
    required this.techniqueId,
    required this.value,
    required this.timestamp,
  });

  final int techniqueId;
  final int value;
  final int timestamp;

  String get name => scoringTechniqueName(techniqueId);
}
