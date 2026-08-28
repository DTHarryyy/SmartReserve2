library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import 'assistant_picker_sheet.dart';
import 'assistant_controller.dart';
import 'assistant_tab.dart';

class AssistantChatPage extends StatefulWidget {
  const AssistantChatPage({super.key, required this.controller});

  final AssistantController controller;

  @override
  State<AssistantChatPage> createState() => _AssistantChatPageState();
}

class _AssistantChatPageState extends State<AssistantChatPage> {
  String? _accountId;
  int? _openPickerRevision;
  bool _historyOpen = false;
  bool _pickerOpen = false;
  bool _pickerOpenScheduled = false;
  bool _handlingPickerResult = false;
  final Set<int> _dismissedPickerRevisions = {};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    _schedulePickerOpen();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_accountId == state.userAccount.id) return;
    _accountId = state.userAccount.id;
    unawaited(widget.controller.initialize(state, freshVisit: true));
  }

  void _schedulePickerOpen() {
    if (!mounted || _pickerOpenScheduled) return;
    _pickerOpenScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pickerOpenScheduled = false;
      unawaited(_maybeOpenPicker());
    });
  }

  bool _canDisplayPicker(AssistantPickerPrompt prompt) =>
      prompt.status == AssistantPickerStatus.ready ||
      prompt.status == AssistantPickerStatus.empty ||
      prompt.status == AssistantPickerStatus.error;

  Future<void> _openActivePickerManually() async {
    final prompt = widget.controller.activePicker;
    if (prompt != null) _dismissedPickerRevisions.remove(prompt.revision);
    await _maybeOpenPicker(manual: true);
  }

  Future<void> _maybeOpenPicker({bool manual = false}) async {
    if (!mounted || _historyOpen || _pickerOpen || _handlingPickerResult) {
      return;
    }
    final prompt = widget.controller.activePicker;
    if (prompt == null || !_canDisplayPicker(prompt)) return;
    if (!manual && _dismissedPickerRevisions.contains(prompt.revision)) return;
    if (_openPickerRevision == prompt.revision) return;

    final state = AppScope.of(context);
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _pickerOpen = true;
      _openPickerRevision = prompt.revision;
    });
    final result = await showAssistantPickerSheet(
      context,
      prompt: prompt,
      state: state,
    );
    if (!mounted) return;
    if (result != null) {
      _dismissedPickerRevisions.add(prompt.revision);
    }
    setState(() {
      _pickerOpen = false;
      _openPickerRevision = null;
    });
    if (result == null) {
      _dismissedPickerRevisions.add(prompt.revision);
      return;
    }
    if (widget.controller.activePicker?.revision != prompt.revision) {
      return;
    }
    setState(() => _handlingPickerResult = true);
    try {
      switch (result.action) {
        case AssistantPickerResultAction.retry:
          await widget.controller.retryActivePicker(state);
          break;
        case AssistantPickerResultAction.select:
          switch (result.kind) {
            case AssistantPickerKind.facility:
              final facility = result.facility;
              if (facility != null) {
                await widget.controller.selectFacility(facility, state);
              }
              break;
            case AssistantPickerKind.date:
              final date = result.date;
              if (date != null) await widget.controller.selectDate(date, state);
              break;
            case AssistantPickerKind.time:
              final start = result.startHour;
              final end = result.endHour;
              if (start != null && end != null) {
                await widget.controller.selectTime(start, end, state);
              }
              break;
          }
          break;
      }
    } finally {
      if (!mounted) return;
      setState(() => _handlingPickerResult = false);
      _schedulePickerOpen();
    }
  }

  Future<void> _showHistory() async {
    setState(() => _historyOpen = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) {
          final state = AppScope.of(context);
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * .68,
              child: AnimatedBuilder(
                animation: widget.controller,
                builder: (context, _) {
                  final conversations = widget.controller.conversations;
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 12, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text('Chat history', style: sans(18, w: 600)),
                            ),
                            IconButton(
                              tooltip: 'Refresh chat history',
                              onPressed: state.assistantHistoryAvailable
                                  ? () => widget.controller.refreshHistory(state)
                                  : null,
                              icon: const Icon(Icons.refresh_rounded),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () async {
                              await widget.controller.newConversation(state);
                              if (sheetContext.mounted) Navigator.pop(sheetContext);
                            },
                            icon: const Icon(Icons.edit_note_rounded),
                            label: const Text('New chat'),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: conversations.isEmpty
                            ? Center(
                                child: Text(
                                  state.assistantHistoryAvailable
                                      ? 'No saved chats yet.'
                                      : 'Chat history is available after you sign in.',
                                  style: sans(12.5, color: context.srColors.textMuted),
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : ListView.separated(
                                itemCount: conversations.length,
                                separatorBuilder: (_, _) => Divider(
                                  height: 1,
                                  color: context.srColors.divider,
                                ),
                                itemBuilder: (context, index) {
                                  final item = conversations[index];
                                  final selected = item.id == widget.controller.conversationId;
                                  return ListTile(
                                    selected: selected,
                                    leading: Icon(
                                      selected
                                          ? Icons.forum_rounded
                                          : Icons.chat_bubble_outline_rounded,
                                      color: selected ? context.srColors.brand : null,
                                    ),
                                    title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                    subtitle: Text(
                                      _historyDate(item.lastActivityAt),
                                      style: sans(11, color: context.srColors.textMuted),
                                    ),
                                    onTap: () async {
                                      await widget.controller.openConversation(item, state);
                                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      );
    } finally {
      if (!mounted) return;
      setState(() => _historyOpen = false);
      _schedulePickerOpen();
    }
  }

  static String _historyDate(DateTime value) {
    final local = value.toLocal();
    return '${local.month}/${local.day}/${local.year} · '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.srColors;
    return Scaffold(
      backgroundColor: colors.canvas,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: colors.isDark
                ? [const Color(0xFF0C2039), colors.canvas, colors.canvas]
                : [const Color(0xFFEAF6FF), colors.canvas, colors.canvas],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _ChatHeader(onHistory: _showHistory),
              Expanded(
                child: AssistantTab(
                  controller: widget.controller,
                  onOpenPicker: _openActivePickerManually,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.onHistory});

  final Future<void> Function() onHistory;

  @override
  Widget build(BuildContext context) {
    final colors = context.srColors;
    return Container(
      height: 66,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: colors.isDark ? .92 : .82),
        border: Border(bottom: BorderSide(color: colors.glassLine2)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 19),
          ),
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [colors.brand, colors.accent]),
            ),
            child: const Icon(Icons.auto_awesome_rounded, size: 18, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SmartReserve AI', style: sans(15, w: 600, tracking: -.02)),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: colors.accent, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 5),
                    Text('Reservation assistant', style: sans(10.5, color: colors.textMuted)),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Chat history and new chat',
            onPressed: () {
              unawaited(onHistory());
            },
            icon: const Icon(Icons.more_horiz_rounded, size: 24),
          ),
        ],
      ),
    );
  }
}
