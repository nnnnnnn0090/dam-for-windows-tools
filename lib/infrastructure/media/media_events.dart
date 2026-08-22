// Project: DAM for Windows Tools
// File: media/media_events.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import '../../domain/tracks.dart';

typedef PlaybackStageHandler = void Function(
  String videoId,
  PlaybackStage stage,
  String detail,
);

typedef DiagnosticLogHandler = void Function(String message);
