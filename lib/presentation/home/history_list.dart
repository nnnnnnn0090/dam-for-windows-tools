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

/// 利用可能な横幅に応じて、表形式とコンパクト形式を切り替える履歴一覧です。
class HistoryList extends StatelessWidget {
  /// 表示対象履歴と、動画選択操作を行うコントローラーを受け取ります。
  const HistoryList({
    super.key,
    required this.tracks,
    required this.controller,
  });

  final List<TrackView> tracks;
  final AppController controller;

  /// 760ピクセルを境に、情報を欠かさず最適な行レイアウトを選びます。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= 760
          ? _DesktopHistory(tracks: tracks, controller: controller)
          : _CompactHistory(tracks: tracks, controller: controller),
    );
  }
}

/// 広いウィンドウで列位置を揃えて表示する履歴テーブルです。
class _DesktopHistory extends StatelessWidget {
  /// 表示対象履歴と操作先を受け取ります。
  const _DesktopHistory({required this.tracks, required this.controller});

  final List<TrackView> tracks;
  final AppController controller;

  /// 固定ヘッダーとスクロール可能な履歴行を構築します。
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

  /// 動画選択を実行し、検証エラーを画面下の通知として表示します。
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

/// デスクトップ履歴の列名と幅比率を定義するヘッダーです。
class _HistoryColumns extends StatelessWidget {
  /// 固定内容の列ヘッダーを生成します。
  const _HistoryColumns();

  /// 各履歴行と同じ比率で列名を配置します。
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

/// 履歴ヘッダーの省スペースな列名表示です。
class _ColumnLabel extends StatelessWidget {
  /// 表示する列名を受け取ります。
  const _ColumnLabel(this.text);

  final String text;

  /// 補助色と小さい文字で列名を表示します。
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 11, color: Color(0xff9ca2ac)),
    );
  }
}

/// 1曲のID・曲情報・配信状態・差し替え操作を横並びに表示します。
class _HistoryRow extends StatelessWidget {
  /// 表示内容と動画の選択・解除操作を受け取ります。
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

  /// 列幅をヘッダーと一致させた履歴行を構築します。
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

/// 狭いウィンドウで曲名を優先し、操作を1行に収める履歴一覧です。
class _CompactHistory extends StatelessWidget {
  /// 表示対象履歴と操作先を受け取ります。
  const _CompactHistory({required this.tracks, required this.controller});

  final List<TrackView> tracks;
  final AppController controller;

  /// 曲名・歌手を縦にまとめたスクロール一覧を構築します。
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

  /// 動画選択を実行し、検証エラーを画面下の通知として表示します。
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

/// 空値、省略、等幅表示を統一する履歴セルです。
class _Cell extends StatelessWidget {
  /// 表示値と、ID用等幅・補助表示の指定を受け取ります。
  const _Cell(this.value, {this.monospace = false, this.secondary = false});

  final String value;
  final bool monospace;
  final bool secondary;

  /// 空値をダッシュへ変換し、長い文字列を1行で省略表示します。
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

/// 配信段階を状態別の色と日本語ラベルで表示します。
class _StageText extends StatelessWidget {
  /// 現在セッションの状態を受け取り、永続履歴だけならnullを許可します。
  const _StageText(this.stage);

  final PlaybackStage? stage;

  /// 正常配信・公式退避・失敗・準備中を見分けられる状態表示を構築します。
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

/// 差し替え動画の選択・変更と、登録済み動画の解除を表示します。
class _VideoButtons extends StatelessWidget {
  /// 登録状態と各操作のコールバックを受け取ります。
  const _VideoButtons({
    required this.manual,
    required this.onChoose,
    required this.onClear,
  });

  final bool manual;
  final VoidCallback onChoose;
  final VoidCallback onClear;

  /// 状態に応じて「選択」または「変更」と、必要な場合だけ「解除」を表示します。
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
