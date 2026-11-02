import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../domain/scoring.dart';
import '../domain/settings.dart';
import 'theme.dart';
import 'widgets.dart';

/// 「採点」タブです。表示設定と、検出した歌唱技法の回数を並べます。
class ScoringPage extends StatelessWidget {
  const ScoringPage({super.key, required this.controller});

  final AppController controller;

  void _update(AppSettings next) => unawaited(controller.updateSettings(next));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[
      controller.scoring,
      controller.settings,
    ]),
    builder: (context, _) {
      final settings = controller.settings.value;
      final scoring = controller.scoring;
      final last = scoring.lastTechniqueId;
      final ids = settings.scoringShowZeroTechniques
          ? displayedTechniqueIds
          : displayedTechniqueIds
                .where((id) => scoring.countOf(id) > 0)
                .toList(growable: false);
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
                      width: 300,
                      child: SettingCheckbox(
                        label: 'DAM画面に表示',
                        description: '歌唱技法の回数をDAM本体の採点画面へ重ねて表示します。',
                        value: settings.scoringOverlayEnabled,
                        onChanged: (v) => _update(
                          settings.copyWith(scoringOverlayEnabled: v),
                        ),
                      ),
                    ),
                    const VerticalDivider(),
                    SizedBox(
                      width: 300,
                      child: SettingCheckbox(
                        label: '0回の技法も表示',
                        description: 'まだ検出されていない歌唱技法も薄く並べ、最初から全種類を表示します。',
                        value: settings.scoringShowZeroTechniques,
                        onChanged: (v) => _update(
                          settings.copyWith(scoringShowZeroTechniques: v),
                        ),
                      ),
                    ),
                    const VerticalDivider(),
                    const SizedBox(width: 12),
                    StatusDot(
                      scoring.active ? AppColors.ok : const Color(0xff8d939c),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      scoring.active ? '採点中' : '採点待機中',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    if (last != null) ...<Widget>[
                      const SizedBox(width: 24),
                      const Text(
                        '直近',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          techniqueName(last),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                    const Spacer(),
                    TextButton(
                      onPressed: scoring.total == 0
                          ? null
                          : controller.resetScoring,
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
                    PanelHeader(
                      '歌唱表現',
                      trailing: <Widget>[
                        Text(
                          '合計 ${scoring.total} 回',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xffa5abb4),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                    const Divider(),
                    Expanded(
                      child: ids.isEmpty
                          ? const Center(
                              child: Text(
                                '歌唱技法を検出すると表示されます',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xff858b94),
                                ),
                              ),
                            )
                          : GridView.builder(
                              key: const Key('scoring-technique-grid'),
                              padding: const EdgeInsets.all(10),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 160,
                                    mainAxisExtent: 84,
                                    crossAxisSpacing: 6,
                                    mainAxisSpacing: 6,
                                  ),
                              itemCount: ids.length,
                              itemBuilder: (context, index) => _TechniqueTile(
                                id: ids[index],
                                count: scoring.countOf(ids[index]),
                                latest:
                                    last != null &&
                                    canonicalTechniqueId(last) == ids[index],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _TechniqueTile extends StatelessWidget {
  const _TechniqueTile({
    required this.id,
    required this.count,
    required this.latest,
  });

  final int id;
  final int count;
  final bool latest;

  @override
  Widget build(BuildContext context) {
    final name = techniqueName(id);
    final detected = count > 0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: latest ? const Color(0xff1b2731) : const Color(0xff191c21),
        border: Border.all(
          color: latest ? AppColors.tabIndicator : const Color(0xff30353d),
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
                  techniqueAsset(id),
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
