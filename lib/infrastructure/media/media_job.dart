// Project: DAM for Windows Tools
// File: media/media_job.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:async';
import 'dart:io';

/// SidecarのURL置換要求へ返す、登録済みジョブの公開情報です。
class MediaRegistration {
  /// 内部ジョブIDとDAMが再生するローカルURLを生成します。
  const MediaRegistration({required this.jobId, required this.localUrl});

  final String jobId;
  final String localUrl;
}

/// 1回のローカル再生について、入力候補・生成状態・中継資産を保持します。
///
/// この型はセッション中だけ存在し、終了時にURLやファイルパスとともに破棄されます。
class MediaJob {
  /// 登録時点の動画情報と出力先から未開始ジョブを生成します。
  MediaJob({
    required this.id,
    required this.videoId,
    required this.highUrl,
    required this.lowUrl,
    required this.manualSource,
    required this.skipMs,
    required this.outputDirectory,
  });

  final String id;
  final String videoId;
  Uri? highUrl;
  Uri? lowUrl;
  final File? manualSource;
  final int skipMs;
  final Directory outputDirectory;
  final Completer<bool> completed = Completer<bool>();
  final Map<String, Uri> proxyAssets = <String, Uri>{};
  bool transcodeStarted = false;
  bool firstSegmentsReported = false;
  bool forceFallback = false;
  Process? ffmpegProcess;
}
