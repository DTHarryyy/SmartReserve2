import 'package:flutter/material.dart';

import '../model/notice.dart';
import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

class ErrorBar extends StatelessWidget {
  const ErrorBar({
    super.key,
    required this.text,
    required this.onJumpToFirst,
    required this.onDismiss,
    this.actionLabel = 'Go to first issue',
  });

  final String text;
  final VoidCallback onJumpToFirst;
  final VoidCallback onDismiss;
  final String actionLabel;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      constraints: const BoxConstraints(maxWidth: 620),
      padding: const EdgeInsets.fromLTRB(15, 11, 13, 11),
      decoration: BoxDecoration(
        color: SR.ink,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x4D10141A),
            blurRadius: 40,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: SR.redBright,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(text, style: sans(12, height: 1.5, color: SR.surface)),
          ),
          const SizedBox(width: 12),
          DarkBarButton(label: actionLabel, onPressed: onJumpToFirst),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            label: 'Dismiss',
            child: Hoverable(
              builder: (context, hovered) => GestureDetector(
                onTap: onDismiss,
                child: Text(
                  '✕',
                  style: sans(
                    12,
                    color: Color(hovered ? 0xCCFFFFFF : 0x80FFFFFF),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class DarkBarButton extends StatelessWidget {
  const DarkBarButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.solid = false,
  });

  final String label;
  final VoidCallback onPressed;

  final bool solid;

  @override
  Widget build(BuildContext context) => Hoverable(
    builder: (context, hovered) => GestureDetector(
      onTap: onPressed,
      child: AnimatedContainer(
        duration: SR.stateChange,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: solid ? SR.surface : Color(hovered ? 0x33FFFFFF : 0x1AFFFFFF),
          borderRadius: BorderRadius.circular(7),
          border: solid ? null : Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: Text(
          label,
          style: sans(11, w: 600, color: solid ? SR.ink : SR.surface),
        ),
      ),
    ),
  );
}

class SrToast extends StatelessWidget {
  const SrToast({super.key, required this.message});

  final ToastMessage message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: TweenAnimationBuilder<double>(
      key: ValueKey(message.text),
      tween: Tween(begin: 0, end: 1),
      duration: SR.entrance,
      curve: SR.easing,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 6),
          child: child,
        ),
      ),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: SR.surface,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: SR.border),
          boxShadow: SR.toastShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                color: toneDot(message.tone),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 9),
            Flexible(
              child: Text(
                message.text,
                style: sans(12, height: 1.5, color: SR.ink2),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Color toneDot(AdvisoryTone tone) => switch (tone) {
  AdvisoryTone.good => SR.green,
  AdvisoryTone.info => SR.blue,
  AdvisoryTone.warn => SR.orange,
  AdvisoryTone.block => SR.red,
};

class UndoBar extends StatelessWidget {
  const UndoBar({
    super.key,
    required this.offer,
    required this.onUndo,
    required this.onDismiss,
  });

  final UndoOffer offer;
  final VoidCallback onUndo;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: TweenAnimationBuilder<double>(
      key: ValueKey(offer.label),
      tween: Tween(begin: 0, end: 1),
      duration: SR.entrance,
      curve: SR.easing,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 6),
          child: child,
        ),
      ),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.fromLTRB(15, 10, 12, 10),
        decoration: BoxDecoration(
          color: SR.ink,
          borderRadius: BorderRadius.circular(12),
          boxShadow: SR.toastShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                offer.label,
                style: sans(12, height: 1.5, color: SR.surface),
              ),
            ),
            const SizedBox(width: 14),
            DarkBarButton(label: '↺ Undo', onPressed: onUndo, solid: true),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: 'Dismiss',
              child: Hoverable(
                builder: (context, hovered) => GestureDetector(
                  onTap: onDismiss,
                  child: Text(
                    '✕',
                    style: sans(
                      12,
                      color: Color(hovered ? 0xCCFFFFFF : 0x80FFFFFF),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class GuardDialog extends StatelessWidget {
  const GuardDialog({
    super.key,
    required this.hasStoredDraft,
    required this.onStay,
    required this.onKeepDraft,
    required this.onDiscard,
  });

  final bool hasStoredDraft;
  final VoidCallback onStay;
  final VoidCallback onKeepDraft;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.transparent,
    elevation: 0,
    insetPadding: const EdgeInsets.all(24),
    child: Container(
      constraints: const BoxConstraints(maxWidth: 400),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: SR.dialogShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Leave without saving?',
            style: sans(15, w: 600, tracking: -.01),
          ),
          const SizedBox(height: 7),
          Text(
            hasStoredDraft
                ? 'This facility is not published yet. Its fields and its map '
                      'pin are already held in the local draft, so you can '
                      'pick it up later.'
                : 'This facility is not published yet. Keep the draft and '
                      'everything, including the map pin, is waiting when you '
                      'come back.',
            style: sans(12.5, height: 1.65, color: SR.ink4),
          ),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              SrButton(label: 'Keep editing', onPressed: onStay),
              SrButton(label: 'Save draft & leave', onPressed: onKeepDraft),
              SrButton(
                label: 'Discard',
                kind: SrButtonKind.dangerSolid,
                onPressed: onDiscard,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
