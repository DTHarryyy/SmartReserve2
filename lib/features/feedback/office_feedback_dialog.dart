import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../model/feedback.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/rating_display.dart';

/// Lets a renter rate the reservation office's service. [prompted] is the
/// after-visit invitation, which offers "Not now" instead of "Cancel".
/// Resolves to true when the rating was sent.
Future<bool?> showOfficeFeedbackDialog(
  BuildContext context, {
  required AppState state,
  bool prompted = false,
}) => showDialog<bool>(
  context: context,
  builder: (_) => _OfficeFeedbackDialog(state: state, prompted: prompted),
);

class _OfficeFeedbackDialog extends StatefulWidget {
  const _OfficeFeedbackDialog({required this.state, required this.prompted});

  final AppState state;
  final bool prompted;

  @override
  State<_OfficeFeedbackDialog> createState() => _OfficeFeedbackDialogState();
}

class _OfficeFeedbackDialogState extends State<_OfficeFeedbackDialog> {
  int _overall = 0;
  int? _responsiveness;
  int? _helpfulness;
  int? _clarity;
  final _comment = TextEditingController();
  String? _error;
  bool _sending = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final error = await widget.state.submitOfficeFeedback(
      overall: _overall,
      responsiveness: _responsiveness,
      helpfulness: _helpfulness,
      clarity: _clarity,
      comment: _comment.text,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _sending = false;
        _error = error;
      });
    }
  }

  Widget _dimension(String label, int? value, ValueChanged<int?> onChanged) {
    final c = context.srColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: SrType.body(w: 500))),
          for (var i = 1; i <= 5; i++)
            Semantics(
              button: true,
              label: '$label $i of 5',
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _sending ? null : () => onChanged(value == i ? null : i),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    (value ?? 0) >= i
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    size: 20,
                    color: (value ?? 0) >= i ? SrTone.warning.solid : c.border,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final tier = FeedbackRating.fromValue(_overall);
    final length = _comment.text.trim().length;
    return AlertDialog(
      title: const Text('Rate our office'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.prompted
                    ? 'Thanks for rating the facility. How did the reservation '
                          'office treat you?'
                    : 'How is the reservation office handling your requests? '
                          'This goes to the office, not a facility.',
                style: SrType.bodySm(color: c.muted),
              ),
              const SizedBox(height: SR.space16),
              Center(
                child: SrRatingInput(
                  key: const Key('office-feedback-overall'),
                  value: _overall,
                  enabled: !_sending,
                  onChanged: (value) => setState(() => _overall = value),
                ),
              ),
              const SizedBox(height: SR.space4),
              Center(
                child: Text(
                  tier?.label ?? 'Overall service',
                  style: SrType.caption(
                    w: 600,
                    color: tier?.foreground ?? c.muted,
                  ),
                ),
              ),
              const SizedBox(height: SR.space12),
              _dimension(
                'Response time',
                _responsiveness,
                (v) => setState(() => _responsiveness = v),
              ),
              _dimension(
                'Staff helpfulness',
                _helpfulness,
                (v) => setState(() => _helpfulness = v),
              ),
              _dimension(
                'Clear process & instructions',
                _clarity,
                (v) => setState(() => _clarity = v),
              ),
              const SizedBox(height: SR.space12),
              TextField(
                key: const Key('office-feedback-comment'),
                controller: _comment,
                minLines: 3,
                maxLines: 5,
                enabled: !_sending,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Anything the office should know? (optional)',
                  counterText: '$length/${FeedbackLimits.commentMax}',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: SR.space8),
                Text(
                  _error!,
                  key: const Key('office-feedback-error'),
                  style: SrType.bodySm(color: c.red),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.pop(context, false),
          child: Text(widget.prompted ? 'Not now' : 'Cancel'),
        ),
        FilledButton(
          key: const Key('office-feedback-submit'),
          onPressed:
              _overall == 0 || _sending || length > FeedbackLimits.commentMax
              ? null
              : _submit,
          child: Text(_sending ? 'Sending…' : 'Send feedback'),
        ),
      ],
    );
  }
}
