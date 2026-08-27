library;

import 'package:flutter/material.dart';

import '../../theme/sr_tokens.dart';
import 'assistant_controller.dart';
import 'assistant_tab.dart';

import '../../theme/sr_theme.dart';

class AssistantChatPage extends StatelessWidget {
  const AssistantChatPage({super.key, required this.controller});

  final AssistantController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.srColors.bg,
    appBar: AppBar(
      backgroundColor: SR.primary,
      foregroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      titleSpacing: 0,
      flexibleSpace: const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1A73E8), Color(0xFF00A8EF)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
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
            color: Colors.white,
          ),
        ),
      ),
      title: Text(
        'SmartReserve Assistant',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sans(16, w: 600, tracking: -.01, color: Colors.white),
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: SR.onDarkLine),
      ),
    ),
    body: AssistantTab(controller: controller),
  );
}
