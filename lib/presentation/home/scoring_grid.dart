// Project: DAM for Windows Tools
// File: home/scoring_grid.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';

import '../../domain/scoring.dart';

class ScoringGrid extends StatelessWidget {
  const ScoringGrid({
    super.key,
    required this.counts,
    required this.latestTechniqueId,
  });

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
