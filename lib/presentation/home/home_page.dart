// Project: DAM for Windows Tools
// File: home/home_page.dart
// Copyright (c) 2026 nnnnnnn0090. All rights reserved.
// Author: nnnnnnn0090
// SPDX-License-Identifier: GPL-3.0-or-later
// Created: 2026-08-23

import 'package:flutter/material.dart';

import '../../application/app_controller.dart';
import 'app_header.dart';
import 'fatal_error_view.dart';
import 'page_tabs.dart';
import 'scoring_page.dart';
import 'video_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedPage = 0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return Scaffold(
          appBar: AppHeader(controller: controller),
          body: controller.fatalError == null
              ? _workspace(controller)
              : FatalErrorView(error: controller.fatalError!),
        );
      },
    );
  }

  Widget _workspace(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PageTabs(
          selectedIndex: _selectedPage,
          onSelected: (index) => setState(() => _selectedPage = index),
        ),
        Expanded(
          child: _selectedPage == 0
              ? VideoPage(controller: controller)
              : ScoringPage(controller: controller),
        ),
      ],
    );
  }
}
