// Project: DAM for Windows Tools
// File: scoring.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

/// DAMが通知する採点技法IDと、GUIに表示する日本語名の対応表です。
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

/// GUIで常時表示する採点技法を、重複するビブラートIDをまとめた順で定義します。
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

/// 種類別に分かれたビブラートIDを、共通表示用IDへまとめます。
int canonicalScoringTechniqueId(int id) => id >= 30 && id <= 38 ? 30 : id;

/// 採点技法IDを表示名へ変換し、未知のIDは「不明」として扱います。
String scoringTechniqueName(int id) {
  if (id < 0 || id >= scoringTechniqueNames.length) return '不明';
  return scoringTechniqueNames[id];
}

/// 採点技法IDに対応する同梱アイコンのアセットパスを返します。
String scoringTechniqueAsset(int id) {
  final canonical = canonicalScoringTechniqueId(id);
  return 'assets/scoring/technique_${canonical.toString().padLeft(2, '0')}.png';
}

/// 再生中にDAMから届いた1回分の歌唱技法検出を表します。
class ScoringEvent {
  /// 技法ID、加算回数、DAM側の検出時刻からイベントを生成します。
  const ScoringEvent({
    required this.techniqueId,
    required this.value,
    required this.timestamp,
  });

  final int techniqueId;
  final int value;
  final int timestamp;

  /// 技法IDに対応する、GUI表示用の日本語名を返します。
  String get name => scoringTechniqueName(techniqueId);
}
