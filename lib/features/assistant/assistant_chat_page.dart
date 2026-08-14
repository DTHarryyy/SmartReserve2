/// A dedicated full-screen chat surface for the assistant.
///
/// Pushed on top of the student shell instead of living inline as a
/// bottom-nav tab, so the AI thread reads like its own messaging screen:
/// the app bar carries only a back button and the assistant's name — no
/// account header, no verification pill, no bottom nav underneath.
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
      // A frosted, translucent bar — the iOS large-title-nav feel — rather
      // than the app's usual flat opaque header.
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
          icon: const Icon(Icons.chevron_left_rounded, size: 30, color: SR.blue),
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
