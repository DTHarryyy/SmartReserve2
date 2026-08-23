import 'package:flutter/material.dart';

import '../model/decision_check.dart';
import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

class CheckList extends StatelessWidget {
  const CheckList({
    super.key,
    required this.summary,
    required this.checks,
    this.labelWidth = 118,
  });

  final CheckSummary summary;
  final List<DecisionCheck> checks;
  final double labelWidth;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: summary.background,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: summary.borderColor),
        ),
        child: Text(
          summary.text,
          style: sans(12, w: 600, height: 1.45, color: summary.foreground),
        ),
      ),
      for (final check in checks)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: SR.dividerSoft)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 17,
                height: 17,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: check.outcome.background,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Icon(
                  check.outcome.mark,
                  size: 11,
                  color: check.outcome.foreground,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: labelWidth,
                child: Text(
                  check.label,
                  style: sans(11.5, w: 500, color: SR.ink2),
                ),
              ),
              Expanded(
                child: Text(
                  check.value,
                  style: sans(
                    11.5,
                    height: 1.5,
                    color: check.outcome.valueColor,
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

class ReasonBox extends StatefulWidget {
  const ReasonBox({
    super.key,
    required this.title,
    required this.placeholder,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onCancel,
    this.tone = ReasonTone.danger,
  });

  final String title;
  final String placeholder;
  final String confirmLabel;
  final ValueChanged<String> onConfirm;
  final VoidCallback onCancel;
  final ReasonTone tone;

  @override
  State<ReasonBox> createState() => _ReasonBoxState();
}

enum ReasonTone { danger, neutral }

class _ReasonBoxState extends State<ReasonBox> {
  final _controller = TextEditingController();
  bool _attempted = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final reason = _controller.text.trim();
    if (reason.isEmpty) {
      setState(() => _attempted = true);
      return;
    }
    widget.onConfirm(reason);
  }

  @override
  Widget build(BuildContext context) {
    final danger = widget.tone == ReasonTone.danger;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: danger ? SR.redTint : SR.surfaceSubtle,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: danger ? SR.redLine : SR.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SrLabel(widget.title, required: true),
          SrTextField(
            controller: _controller,
            placeholder: widget.placeholder,
            fontSize: 12.5,
            minLines: 3,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            hasError: _attempted && _controller.text.trim().isEmpty,
            onChanged: (_) => setState(() {}),
          ),
          if (_attempted && _controller.text.trim().isEmpty)
            const SrErrorText(
              'A reason is required — the other person reads it verbatim.',
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              SrButton(
                label: widget.confirmLabel,
                kind: danger ? SrButtonKind.dangerSolid : SrButtonKind.primary,
                onPressed: _confirm,
              ),
              const SizedBox(width: 8),
              SrButton(label: 'Cancel', onPressed: widget.onCancel),
            ],
          ),
        ],
      ),
    );
  }
}

class PanelCard extends StatelessWidget {
  const PanelCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: padding ?? const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: SR.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SR.border),
    ),
    child: child,
  );
}

class Initials extends StatelessWidget {
  const Initials({
    super.key,
    required this.text,
    this.size = 36,
    this.fontSize = 12,
  });

  final String text;
  final double size;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: SR.blueTint, shape: BoxShape.circle),
    child: Text(text, style: mono(fontSize, w: 600, color: SR.blueDark)),
  );
}
