// Project: DAM for Windows Tools
// File: remote_access_policy_test.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:io';

import 'package:dam_for_windows_tools/infrastructure/remote/remote_access_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts loopback and RFC1918 IPv4 clients only', () {
    for (final address in <String>[
      '127.0.0.1',
      '10.0.0.1',
      '172.16.0.1',
      '172.31.255.254',
      '192.168.1.2',
      '::1',
    ]) {
      expect(
        RemoteAccessPolicy.isPrivateClient(InternetAddress(address)),
        isTrue,
      );
    }
    for (final address in <String>[
      '8.8.8.8',
      '172.15.0.1',
      '172.32.0.1',
      '169.254.1.1',
    ]) {
      expect(
        RemoteAccessPolicy.isPrivateClient(InternetAddress(address)),
        isFalse,
      );
    }
  });

  test('limits each client to the bounded request rate', () {
    final policy = RemoteAccessPolicy();
    for (
      var index = 0;
      index < RemoteAccessPolicy.maximumRequestsPerMinute;
      index++
    ) {
      expect(policy.isRateAllowed('192.168.1.2'), isTrue);
    }
    expect(policy.isRateAllowed('192.168.1.2'), isFalse);
    expect(policy.isRateAllowed('192.168.1.3'), isTrue);
  });
}
