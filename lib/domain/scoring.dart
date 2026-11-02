/// DAMが通知する採点技法ID(0〜43)の表示名です。30〜38はすべてビブラートです。
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

/// 画面に並べる36種の技法IDです。ビブラートは30へ集約します。
final List<int> displayedTechniqueIds = List<int>.unmodifiable(<int>[
  for (var id = 0; id <= 30; id++) id,
  for (var id = 39; id <= 43; id++) id,
]);

/// 種類別のビブラートIDを表示用の30へまとめます。
int canonicalTechniqueId(int id) => id >= 30 && id <= 38 ? 30 : id;

bool isKnownTechniqueId(int id) => id >= 0 && id < scoringTechniqueNames.length;

String techniqueName(int id) =>
    isKnownTechniqueId(id) ? scoringTechniqueNames[id] : '不明';

String techniqueAsset(int id) {
  final number = canonicalTechniqueId(id).toString().padLeft(2, '0');
  return 'assets/scoring/technique_$number.png';
}
