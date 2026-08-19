library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app/app_scope.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/sr_controls.dart';
import 'assistant_cards.dart';
import 'assistant_controller.dart';

class AssistantTab extends StatefulWidget {
  const AssistantTab({super.key, required this.controller});

  final AssistantController controller;

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

    return ColoredBox(
      color: SR.bg,
      child: Column(
        children: [
          if (state.busyWindowsDegraded) _degradedNotice(),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
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
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AssistantBubble(message: message),
                        if (message.kind == AssistantMessageKind.chips)
                          AssistantChipRow(chips: message.chips, state: state),
                        if (message.kind == AssistantMessageKind.facilities)
                          AssistantFacilityListView(
                            facilities: message.facilities,
                            controller: controller,
                          ),
                        if (message.kind == AssistantMessageKind.reservations)
                          AssistantReservationListView(
                            reservations: message.reservations,
                            controller: controller,
                          ),
                        if (message.kind == AssistantMessageKind.confirm)
                          AssistantConfirmCard(controller: controller),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          if (controller.busy) _typingIndicator(narrow),
          SafeArea(top: false, child: _composerBar(narrow)),
        ],
      ),
    );
  }

  Widget _degradedNotice() => Container(
    margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: SR.amberTint,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SR.amberLine),
    ),
    child: Row(
      children: [
        const Icon(Icons.wifi_off_rounded, size: 14, color: SR.amberTitle),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            "Couldn't reach the live schedule — availability answers are "
            'based on opening hours only.',
            style: sans(11, color: SR.amberInk),
          ),
        ),
      ],
    ),
  );

  Widget _typingIndicator(bool narrow) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Padding(
        padding: EdgeInsets.fromLTRB(narrow ? 14 : 20, 0, narrow ? 14 : 20, 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
            decoration: BoxDecoration(
              color: SR.surface,
              border: Border.all(color: SR.border),
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
      color: SR.muted.withValues(alpha: opacity),
    ),
  );

  Widget _composerBar(bool narrow) {
    final controller = widget.controller;
    final canSend = !controller.busy;
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: SR.surface,
        border: Border(top: BorderSide(color: SR.hairline)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              narrow ? 12 : 20,
              10,
              narrow ? 12 : 20,
              10,
            ),
            child: Row(
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
          ),
        ),
      ),
    );
  }
}

class _ComposerField extends StatefulWidget {
  const _ComposerField({
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;

  @override
  State<_ComposerField> createState() => _ComposerFieldState();
}

class _ComposerFieldState extends State<_ComposerField> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_sync);
  }

  void _sync() {
    if (widget.focusNode.hasFocus != _focused) {
      setState(() => _focused = widget.focusNode.hasFocus);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_sync);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: SR.stateChange,
    constraints: const BoxConstraints(minHeight: 40),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
    decoration: BoxDecoration(
      color: SR.bg,
      borderRadius: BorderRadius.circular(21),
      border: Border.all(
        color: _focused ? SR.blue : SR.border,
        width: _focused ? 1.4 : 1,
      ),
    ),
    child: Semantics(
      textField: true,
      label: 'Message the assistant',
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        minLines: 1,
        maxLines: 4,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.send,
        onSubmitted: widget.onSubmitted,
        cursorColor: SR.blue,
        cursorWidth: 1.5,
        style: sans(13.5, height: 1.4),
        decoration: InputDecoration(
          isDense: true,
          isCollapsed: true,
          border: InputBorder.none,
          hintText: 'Message SmartReserve AI',
          hintStyle: sans(13.5, color: SR.mutedLight),
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
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: enabled
                  ? (hovered ? SR.blueDark : SR.blue)
                  : SR.dividerSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.arrow_upward_rounded,
              size: 18,
              color: enabled ? SR.surface : SR.mutedLight,
            ),
          ),
        ),
      ),
    ),
  );
}
