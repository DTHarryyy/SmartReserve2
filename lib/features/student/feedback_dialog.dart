import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../model/feedback.dart';
import '../../model/reservation.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/rating_display.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_controls.dart';

/// Opens the feedback flow for an eligible completed reservation. Full page
/// below SR.tabletMin, dialog above -- the same split showBookingSheet
/// uses. Returns true when feedback was submitted successfully.
Future<bool?> showFeedbackDialog(
  BuildContext context, {
  required AppState state,
  required ReservationRequest request,
}) {
  if (MediaQuery.sizeOf(context).width < SR.tabletMin) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Rate your visit')),
          body: SafeArea(
            child: _FeedbackForm(state: state, request: request),
          ),
        ),
      ),
    );
  }
  return showDialog<bool>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: SrAdaptiveDialog(
        maxWidth: 460,
        maxHeight: 640,
        child: _FeedbackForm(state: state, request: request),
      ),
    ),
  );
}

class _FeedbackForm extends StatefulWidget {
  const _FeedbackForm({required this.state, required this.request});

  final AppState state;
  final ReservationRequest request;

  @override
  State<_FeedbackForm> createState() => _FeedbackFormState();
}

class _FeedbackFormState extends State<_FeedbackForm> {
  int _rating = 0;
  bool _detailsOpen = false;
  int? _cleanliness;
  int? _condition;
  int? _equipment;
  final _commentController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  bool get _submitting =>
      widget.state.feedbackSubmitting.contains(widget.request.id);

  Future<void> _submit() async {
    if (_rating == 0 || _submitting) return;
    setState(() => _error = null);
    final ok = await widget.state.submitFeedback(
      widget.request,
      rating: _rating,
      comment: _commentController.text.trim(),
      cleanliness: _cleanliness,
      condition: _condition,
      equipment: _equipment,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(
        () => _error =
            widget.state.feedbackError ??
            'That could not be sent. Try again.',
      );
    }
  }

  Widget _categoryRow(String label, int? value, ValueChanged<int?> onChanged) {
    final c = context.srColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: sans(13, w: 500, color: c.text)),
          ),
          for (var i = 1; i <= 5; i++)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onChanged(value == i ? null : i),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    (value ?? 0) >= i
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    size: 18,
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
    final request = widget.request;
    final tier = FeedbackRating.fromValue(_rating);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Text('Rate your visit', style: SrType.title(color: c.text)),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded, size: 20),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: c.border),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(request.facility, style: SrType.heading(color: c.text)),
                const SizedBox(height: 2),
                Text(
                  '${request.date} · ${request.start}–${request.end}',
                  style: SrType.bodySm(color: c.textMuted),
                ),
                const SizedBox(height: 20),
                Center(
                  child: Column(
                    children: [
                      SrRatingInput(
                        value: _rating,
                        enabled: !_submitting,
                        onChanged: (value) => setState(() => _rating = value),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 18,
                        child: Text(
                          tier?.label ?? 'Tap a star to rate',
                          style: sans(
                            13,
                            w: 600,
                            color: tier?.foreground ?? c.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () => setState(() => _detailsOpen = !_detailsOpen),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Icon(
                          _detailsOpen
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                          color: c.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Rate the details (optional)',
                          style: sans(13, w: 500, color: c.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_detailsOpen) ...[
                  const SizedBox(height: 4),
                  _categoryRow(
                    'Cleanliness',
                    _cleanliness,
                    (v) => setState(() => _cleanliness = v),
                  ),
                  _categoryRow(
                    'Facility condition',
                    _condition,
                    (v) => setState(() => _condition = v),
                  ),
                  _categoryRow(
                    'Equipment',
                    _equipment,
                    (v) => setState(() => _equipment = v),
                  ),
                ],
                const SizedBox(height: 16),
                SrTextField(
                  controller: _commentController,
                  placeholder:
                      'What went well? What could be better? (optional)',
                  minLines: 3,
                  maxLines: 4,
                  onChanged: (_) => setState(() {}),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${_commentController.text.length}/'
                      '${FeedbackLimits.commentMax}',
                      style: sans(
                        11,
                        w: 500,
                        color:
                            _commentController.text.length >
                                FeedbackLimits.commentMax
                            ? c.error
                            : c.textMuted,
                      ),
                    ),
                  ),
                ),
                SrErrorText(_error),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: c.border),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SrButton(
            label: _submitting ? 'Submitting…' : 'Submit feedback',
            kind: SrButtonKind.primary,
            expand: true,
            onPressed: (_rating == 0 || _submitting) ? null : _submit,
          ),
        ),
      ],
    );
  }
}
