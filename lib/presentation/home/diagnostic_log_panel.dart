// Project: DAM for Windows Tools
// File: home/diagnostic_log_panel.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/app_controller.dart';
import '../widgets/panel.dart';

class DiagnosticLogPanel extends StatefulWidget {
  const DiagnosticLogPanel({super.key, required this.controller});

  final AppController controller;

  @override
  State<DiagnosticLogPanel> createState() => _DiagnosticLogPanelState();
}

class _DiagnosticLogPanelState extends State<DiagnosticLogPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final logs = widget.controller.logs;
    final text = logs.isEmpty
        ? 'ログはありません'
        : logs.reversed.take(120).toList().reversed.join('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(_expanded ? '診断ログを閉じる' : '診断ログ'),
          ),
        ),
        if (_expanded)
          Panel(
            child: SizedBox(
              height: 150,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    height: 38,
                    child: Row(
                      children: <Widget>[
                        const Padding(
                          padding: EdgeInsets.only(left: 12),
                          child: Text(
                            '診断ログ',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: logs.isEmpty
                              ? null
                              : () => Clipboard.setData(
                                  ClipboardData(text: text),
                                ),
                          child: const Text('コピー'),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(10),
                      child: SelectableText(
                        text,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 11,
                          height: 1.35,
                          color: Color(0xffb7bcc4),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
