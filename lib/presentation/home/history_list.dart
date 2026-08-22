// Project: DAM for Windows Tools
// File: home/history_list.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/app_controller.dart';
import '../../domain/tracks.dart';

class HistoryList extends StatelessWidget {
  const HistoryList({
    super.key,
    required this.tracks,
    required this.controller,
  });

  final List<TrackView> tracks;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= 760
          ? _DesktopHistory(tracks: tracks, controller: controller)
          : _CompactHistory(tracks: tracks, controller: controller),
    );
  }
}

class _DesktopHistory extends StatelessWidget {
  const _DesktopHistory({required this.tracks, required this.controller});

  final List<TrackView> tracks;
  final AppController controller;

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
                onChoose: () => _choose(context, id),
                onClear: () => unawaited(controller.clearManualVideo(id)),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _choose(BuildContext context, String videoId) async {
    try {
      await controller.chooseManualVideo(videoId);
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
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
  const _CompactHistory({required this.tracks, required this.controller});

  final List<TrackView> tracks;
  final AppController controller;

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
                onChoose: () => _choose(context, id),
                onClear: () => unawaited(controller.clearManualVideo(id)),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _choose(BuildContext context, String videoId) async {
    try {
      await controller.chooseManualVideo(videoId);
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
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
