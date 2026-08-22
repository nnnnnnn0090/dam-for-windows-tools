// Project: DAM for Windows Tools
// File: serialization.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:convert';

String prettyJson(Object value) =>
    const JsonEncoder.withIndent('  ').convert(value);
