library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/sr_controls.dart';
import 'assistant_cards.dart';
import 'assistant_controller.dart';

import '../../theme/sr_theme.dart';

class AssistantTab extends StatefulWidget {
  const AssistantTab({super.key, required this.controller, this.onOpenPicker});

  final AssistantController controller;
  final Future<void> Function()? onOpenPicker;

  @override
  State<AssistantTab> createState() => _AssistantTabState();
}

class _AssistantTabState extends State<AssistantTab> {
  final _scroll = ScrollController();
  final _composer = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _scroll.dispose();
    _composer.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: SR.entrance,
        curve: SR.easing,
      );
    });
  }

  void _send() {
    final state = AppScope.of(context);
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    _composer.clear();
    widget.controller.send(text, state);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final narrow = SR.isCompact(width);
    final controller = widget.controller;
    final quickReplies = _latestQuickReplies(controller);

    return ColoredBox(
      color: Colors.transparent,
      child: Column(
        children: [
          if (state.busyWindowsDegraded) _degradedNotice(),
          if (controller.aiDegraded) _aiNotice(),
          if (controller.historySaveFailed) _historyNotice(controller),
          Expanded(
            child: controller.historyLoading
                ? const Center(child: CircularProgressIndicator())
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: ListView.builder(
                        controller: _scroll,
                        padding: EdgeInsets.fromLTRB(
                          narrow ? 14 : 20,
                          16,
                          narrow ? 14 : 20,
                          10,
                        ),
                        itemCount: controller.messages.length,
                        itemBuilder: (context, index) {
                          final message = controller.messages[index];
                          if (message.kind == AssistantMessageKind.chips) {
                            return const SizedBox.shrink();
                          }
                          final previous = index == 0
                              ? null
                              : controller.messages[index - 1];
                          final showDate =
                              previous == null ||
                              !_sameChatDate(
                                previous.createdAt,
                                message.createdAt,
                              );
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (showDate) _dateDivider(message.createdAt),
                              AssistantBubble(message: message),
                              if (message.kind ==
                                  AssistantMessageKind.facilities)
                                AssistantFacilityListView(
                                  facilities: message.facilities,
                                  controller: controller,
                                ),
                              if (message.kind ==
                                  AssistantMessageKind.reservations)
                                AssistantReservationListView(
                                  reservations: message.reservations,
                                  controller: controller,
                                ),
                              if (message.kind == AssistantMessageKind.confirm)
                                AssistantConfirmCard(controller: controller),
                              if (message.kind == AssistantMessageKind.activity)
                                AssistantActivityCard(message: message),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
          ),
          if (controller.busy) _typingIndicator(narrow),
          SafeArea(
            top: false,
            child: _composerBar(narrow, quickReplies, state),
          ),
        ],
      ),
    );
  }

  List<AssistantChipOption> _latestQuickReplies(
    AssistantController controller,
  ) {
    if (controller.messages.isEmpty) {
      return const <AssistantChipOption>[];
    }
    if (controller.activePicker != null ||
        controller.stage == AssistantStage.needFacility ||
        controller.stage == AssistantStage.needDate ||
        controller.stage == AssistantStage.needTime) {
      return const <AssistantChipOption>[];
    }
    final latest = controller.messages.last;
    if (latest.kind == AssistantMessageKind.chips && latest.chips.isNotEmpty) {
      return latest.chips;
    }
    return const <AssistantChipOption>[];
  }

  bool _sameChatDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _dateDivider(DateTime date) => Padding(
    padding: const EdgeInsets.only(top: 2, bottom: 12),
    child: Row(
      children: [
        Expanded(child: Divider(color: context.srColors.glassLine2)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            '${date.month}/${date.day}/${date.year}',
            style: mono(10, color: context.srColors.textMuted),
          ),
        ),
        Expanded(child: Divider(color: context.srColors.glassLine2)),
      ],
    ),
  );

  Widget _historyNotice(AssistantController controller) => Container(
    margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
    padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
    decoration: BoxDecoration(
      color: context.srColors.warningContainer,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.srColors.amberLine),
    ),
    child: Row(
      children: [
        Icon(
          Icons.history_toggle_off_rounded,
          size: 16,
          color: context.srColors.warning,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'This chat could not be saved. Your reservation actions are still safe.',
            style: sans(10.5, color: context.srColors.amberInk),
          ),
        ),
        TextButton(
          onPressed: controller.retryHistorySave,
          child: const Text('Retry'),
        ),
      ],
    ),
  );

  Widget _degradedNotice() => Container(
    margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: context.srColors.amberTint,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.srColors.amberLine),
    ),
    child: Row(
      children: [
        Icon(
          Icons.wifi_off_rounded,
          size: 14,
          color: context.srColors.amberTitle,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            "Couldn't reach the live schedule. Booking choices are paused "
            'until availability can be verified.',
            style: sans(11, color: context.srColors.amberInk),
          ),
        ),
      ],
    ),
  );

  /// Shown when the cloud model could not be reached this turn.
  ///
  /// The answer above it is the deterministic one, which is correct but
  /// blunter, so this says what changed rather than reporting an error.
  /// Deliberately not shown for the kill switch: an assistant running on rules
  /// by configuration is not degraded, it is how the assistant shipped.
  Widget _aiNotice() => Container(
    margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: context.srColors.surfaceSubtle,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.srColors.dividerSoft),
    ),
    child: Row(
      children: [
        Icon(
          Icons.auto_awesome_outlined,
          size: 14,
          color: context.srColors.textMuted,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Answering from your records only right now. Everything below is '
            'still accurate; phrasing may be blunter than usual.',
            style: sans(11, color: context.srColors.textMuted),
          ),
        ),
      ],
    ),
  );

  Widget _typingIndicator(bool narrow) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Padding(
        padding: EdgeInsets.fromLTRB(narrow ? 14 : 20, 0, narrow ? 14 : 20, 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
            decoration: BoxDecoration(
              color: context.srColors.surface,
              border: Border.all(color: context.srColors.border),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _typingDot(1),
                const SizedBox(width: 4),
                _typingDot(.6),
                const SizedBox(width: 4),
                _typingDot(.32),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _typingDot(double opacity) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: context.srColors.muted.withValues(alpha: opacity),
    ),
  );

  Widget _composerBar(
    bool narrow,
    List<AssistantChipOption> quickReplies,
    AppState state,
  ) {
    final controller = widget.controller;
    final canSend = !controller.busy;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: context.srColors.surface.withValues(alpha: .96),
        border: Border(top: BorderSide(color: context.srColors.glassLine2)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              narrow ? 12 : 20,
              12,
              narrow ? 12 : 20,
              10,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (quickReplies.isNotEmpty) ...[
                  _QuickReplyStrip(
                    chips: quickReplies,
                    state: state,
                    enabled: canSend,
                  ),
                  const SizedBox(height: 10),
                ],
                if (controller.activePicker != null) ...[
                  _PickerReopenButton(
                    prompt: controller.activePicker!,
                    enabled: canSend && widget.onOpenPicker != null,
                    onTap: widget.onOpenPicker,
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: _ComposerField(
                        controller: _composer,
                        focusNode: _focusNode,
                        onSubmitted: (_) {
                          if (canSend) _send();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    _SendButton(
                      enabled: canSend,
                      onPressed: canSend ? _send : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PickerReopenButton extends StatelessWidget {
  const _PickerReopenButton({
    required this.prompt,
    required this.enabled,
    required this.onTap,
  });

  final AssistantPickerPrompt prompt;
  final bool enabled;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    final label = switch (prompt.kind) {
      AssistantPickerKind.facility => 'Choose facility',
      AssistantPickerKind.date => 'Choose date',
      AssistantPickerKind.time => 'Choose time',
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        onPressed: enabled && onTap != null
            ? () {
                unawaited(onTap!());
              }
            : null,
        icon: const Icon(Icons.touch_app_rounded, size: 18),
        label: Text(label),
      ),
    );
  }
}

class _QuickReplyStrip extends StatefulWidget {
  const _QuickReplyStrip({
    required this.chips,
    required this.state,
    required this.enabled,
  });

  final List<AssistantChipOption> chips;
  final AppState state;
  final bool enabled;

  @override
  State<_QuickReplyStrip> createState() => _QuickReplyStripState();
}

class _QuickReplyStripState extends State<_QuickReplyStrip> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 50,
    child: Scrollbar(
      controller: _scrollController,
      interactive: true,
      radius: const Radius.circular(999),
      scrollbarOrientation: ScrollbarOrientation.bottom,
      thickness: 2,
      child: ListView.separated(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        primary: false,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: const EdgeInsets.only(bottom: 6),
        itemCount: widget.chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final chip = widget.chips[index];
          return _QuickReplyChip(
            label: chip.label,
            enabled: widget.enabled,
            onTap: () => chip.onSelect(widget.state),
          );
        },
      ),
    ),
  );
}

class _QuickReplyChip extends StatelessWidget {
  const _QuickReplyChip({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.srColors;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: 'Suggestion: $label',
        // Without this the chip's own Text contributes a second label and the
        // node reads "Suggestion: Show my reservations, Show my reservations".
        excludeSemantics: true,
        child: Hoverable(
          enabled: enabled,
          builder: (context, hovered) => GestureDetector(
            onTap: enabled ? onTap : null,
            child: AnimatedContainer(
              duration: SR.stateChange,
              height: 44,
              constraints: const BoxConstraints(maxWidth: 280),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: enabled
                    ? (hovered ? colors.primaryTint : colors.surfaceSubtle)
                    : colors.dividerSoft,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: hovered ? colors.brand : colors.glassLine2,
                ),
                boxShadow: hovered ? SR.focusRingOf(colors.brand) : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    size: 14,
                    color: enabled ? colors.brand : colors.mutedLight,
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(
                        12,
                        w: 600,
                        color: enabled ? colors.ink2 : colors.mutedLight,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerField extends StatelessWidget {
  const _ComposerField({
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: SR.stateChange,
    constraints: const BoxConstraints(minHeight: 46),
    padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 11),
    decoration: BoxDecoration(
      color: context.srColors.surfaceSubtle,
      borderRadius: BorderRadius.circular(23),
    ),
    child: Semantics(
      textField: true,
      label: 'Message the assistant',
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        minLines: 1,
        maxLines: 4,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.send,
        onSubmitted: onSubmitted,
        cursorColor: SR.primary,
        cursorWidth: 1.5,
        style: sans(13.5, height: 1.4),
        decoration: InputDecoration(
          isDense: true,
          isCollapsed: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          hintText: 'Ask about facilities or reservations…',
          hintStyle: sans(13.5, color: context.srColors.mutedLight),
        ),
      ),
    ),
  );
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Send',
    child: Semantics(
      button: true,
      enabled: enabled,
      label: 'Send',
      child: Hoverable(
        enabled: enabled,
        builder: (context, hovered) => GestureDetector(
          onTap: onPressed,
          child: AnimatedContainer(
            duration: SR.stateChange,
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: enabled
                  ? (hovered ? SR.primaryHover : SR.primary)
                  : context.srColors.dividerSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.arrow_upward_rounded,
              size: 20,
              color: enabled ? SR.onDark : context.srColors.mutedLight,
            ),
          ),
        ),
      ),
    ),
  );
}
