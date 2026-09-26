import 'package:flutter/material.dart';

import '../model/notice.dart';
import '../theme/sr_tokens.dart';
import 'responsive_dialog.dart';
import 'sr_controls.dart';

import '../theme/sr_theme.dart';

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
        color: context.srColors.ink,
        borderRadius: BorderRadius.circular(12),
        boxShadow: SR.popoverShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: SR.redBright,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              text,
              style: sans(12, height: 1.5, color: context.srColors.surface),
            ),
          ),
          const SizedBox(width: 12),
          DarkBarButton(label: actionLabel, onPressed: onJumpToFirst),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            label: 'Dismiss',
            child: SizedBox.square(
              dimension: SR.isCompact(MediaQuery.sizeOf(context).width)
                  ? 44
                  : 20,
              child: Hoverable(
                builder: (context, hovered) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onDismiss,
                  child: Center(
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
        constraints: BoxConstraints(
          minHeight: SR.isCompact(MediaQuery.sizeOf(context).width) ? 44 : 0,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: solid ? SR.onDark : Color(hovered ? 0x33FFFFFF : 0x1AFFFFFF),
          borderRadius: BorderRadius.circular(7),
          border: solid ? null : Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: Text(
          label,
          style: sans(11, w: 600, color: solid ? SR.neutralDark : SR.onDark),
        ),
      ),
    ),
  );
}

class SrToast extends StatelessWidget {
  const SrToast({
    super.key,
    required this.message,
    required this.onDismiss,
    required this.onAction,
  });

  final ToastMessage message;
  final VoidCallback onDismiss;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: '${toneLabel(message.tone)}: ${message.text}',
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: context.srColors.surface,
        borderRadius: BorderRadius.circular(SR.rMd),
        border: Border.all(color: context.srColors.border),
        boxShadow: SR.toastShadow,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: toneTint(context, message.tone),
              shape: BoxShape.circle,
            ),
            child: Icon(
              toneIcon(message.tone),
              size: 17,
              color: toneDot(context, message.tone),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style:
                  sans(
                    12,
                    height: 1.45,
                    color: context.srColors.ink2,
                    decoration: TextDecoration.none,
                  ).copyWith(
                    decorationColor: Colors.transparent,
                    decorationStyle: TextDecorationStyle.solid,
                  ),
            ),
          ),
          if (message.action case final action?) ...[
            const SizedBox(width: 8),
            LightBarButton(label: action.label, onPressed: onAction),
          ],
          Semantics(
            button: true,
            label: 'Dismiss notification',
            child: SizedBox.square(
              dimension: 44,
              child: IconButton(
                onPressed: onDismiss,
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: context.srColors.ink3,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class LightBarButton extends StatelessWidget {
  const LightBarButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        foregroundColor: context.srColors.primaryDeep,
        side: BorderSide(color: context.srColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      child: Text(
        label,
        style: sans(11, w: 600, color: context.srColors.primaryDeep),
      ),
    ),
  );
}

Color toneDot(BuildContext context, AdvisoryTone tone) => switch (tone) {
  AdvisoryTone.good => SR.green,
  AdvisoryTone.info => context.srColors.info,
  AdvisoryTone.warn => SR.orange,
  AdvisoryTone.block => context.srColors.red,
};

Color toneTint(BuildContext context, AdvisoryTone tone) => switch (tone) {
  AdvisoryTone.good => context.srColors.greenTint,
  AdvisoryTone.info => context.srColors.infoContainer,
  AdvisoryTone.warn => context.srColors.amberTint,
  AdvisoryTone.block => context.srColors.redTint,
};

IconData toneIcon(AdvisoryTone tone) => switch (tone) {
  AdvisoryTone.good => Icons.check_rounded,
  AdvisoryTone.info => Icons.info_outline_rounded,
  AdvisoryTone.warn => Icons.warning_amber_rounded,
  AdvisoryTone.block => Icons.error_outline_rounded,
};

String toneLabel(AdvisoryTone tone) => switch (tone) {
  AdvisoryTone.good => 'Success',
  AdvisoryTone.info => 'Information',
  AdvisoryTone.warn => 'Warning',
  AdvisoryTone.block => 'Error',
};

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
  Widget build(BuildContext context) => SrAdaptiveDialog(
    maxWidth: 400,
    maxHeight: 520,
    fullScreenOnCompact: false,
    padding: EdgeInsets.all(
      SR.isCompact(MediaQuery.sizeOf(context).width) ? 18 : 22,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Leave without saving?', style: sans(15, w: 600, tracking: -.01)),
        const SizedBox(height: 7),
        Text(
          hasStoredDraft
              ? 'This facility is not published yet. Its fields and its map '
                    'pin are already held in the local draft, so you can '
                    'pick it up later.'
              : 'This facility is not published yet. Keep the draft and '
                    'everything, including the map pin, is waiting when you '
                    'come back.',
          style: sans(12.5, height: 1.65, color: context.srColors.ink4),
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
  );
}
