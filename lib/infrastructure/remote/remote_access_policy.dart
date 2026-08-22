// Project: DAM for Windows Tools
// File: remote/remote_access_policy.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'dart:io';

/// Webリモコンを家庭内IPv4へ限定し、端末単位の操作頻度を制限します。
class RemoteAccessPolicy {
  static const int maximumRequestsPerMinute = 180;
  static const int maximumTrackedAddresses = 128;

  final Map<String, List<int>> _requestTimes = <String, List<int>>{};

  /// 指定アドレスの直近1分間の要求数を記録し、上限以内か返します。
  bool isRateAllowed(String address) => _consumeRate(address);

  /// サーバー終了時に、端末別の一時的な要求記録を破棄します。
  void clear() => _requestTimes.clear();

  /// 古い要求時刻を除去してから今回の要求を消費し、追跡表も上限管理します。
  bool _consumeRate(String address) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - const Duration(minutes: 1).inMilliseconds;
    final times = _requestTimes.putIfAbsent(address, () => <int>[])
      ..removeWhere((value) => value < cutoff);
    if (times.length >= maximumRequestsPerMinute) return false;
    times.add(now);
    if (_requestTimes.length > maximumTrackedAddresses) {
      _requestTimes.removeWhere(
        (_, values) => values.isEmpty || values.last < cutoff,
      );
    }
    return true;
  }

  /// ループバックまたはRFC 1918のIPv4アドレスだけを接続元として許可します。
  static bool isPrivateClient(InternetAddress? address) {
    if (address == null || address.isLoopback) return address != null;
    if (address.type != InternetAddressType.IPv4) return false;
    final parts = address.address.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((part) => part == null)) return false;
    final first = parts[0]!;
    final second = parts[1]!;
    return first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
  }

  /// 仮想NICを避け、Wi-Fi・Ethernetを優先したQRコード表示用LANアドレスを探します。
  static Future<String?> findPreferredLanAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final candidates = <({String address, int score})>[];
    for (final interface in interfaces) {
      final name = interface.name.toLowerCase();
      var score = 0;
      if (name.contains('wi-fi') || name.contains('wlan')) score += 30;
      if (name.contains('ethernet')) score += 20;
      if (name.contains('virtual') ||
          name.contains('vethernet') ||
          name.contains('vmware') ||
          name.contains('virtualbox') ||
          name.contains('tailscale')) {
        score -= 100;
      }
      for (final address in interface.addresses) {
        if (isPrivateClient(address) && !address.isLoopback) {
          candidates.add((address: address.address, score: score));
        }
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort((left, right) => right.score.compareTo(left.score));
    return candidates.first.address;
  }
}
