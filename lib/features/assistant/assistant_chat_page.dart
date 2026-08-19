library;

import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/sr_tokens.dart';
import 'assistant_controller.dart';
import 'assistant_tab.dart';

class AssistantChatPage extends StatelessWidget {
  const AssistantChatPage({super.key, required this.controller});

  final AssistantController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: SR.bg,
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      titleSpacing: 0,
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
          child: Container(color: SR.surface.withValues(alpha: .78)),
        ),
      ),
      leading: Semantics(
        button: true,
        label: 'Back',
        child: IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(
            Icons.chevron_left_rounded,
            size: 30,
            color: SR.blue,
          ),
        ),
      ),
      title: Text('SmartReserve AI', style: sans(16, w: 600, tracking: -.01)),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: SR.border),
      ),
    ),
    body: AssistantTab(controller: controller),
  );
}
