import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../model/payment.dart';
import '../../model/reservation.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/sr_controls.dart';

/// Administrator view of extra time: pending extension requests, on-site
/// extensions, checkout (optionally backdated) and the resulting charges.
class ExtraTimeCard extends StatelessWidget {
  const ExtraTimeCard({super.key, required this.state, required this.request});

  final AppState state;
  final ReservationRequest request;

  bool get _busy => state.reservationActionsPending.contains(request.id);

  static String _clock(DateTime value) =>
      formatClock12(value.hour + value.minute / 60);

  @override
  Widget build(BuildContext context) {
    final now = campusNow();
    final active = [
      for (final occurrence in request.occurrences)
        if (occurrence.isBooked &&
            (occurrence.stage == BookingStage.booked ||
                occurrence.stage == BookingStage.checkedIn))
          occurrence,
    ];
    final charges = request.timeCharges;
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Extra time and checkout', style: SrType.subhead()),
          const SizedBox(height: SR.space2),
          Text(
            request.isCampusBooking
                ? 'Campus use is free until 5:00 PM. Time after 5:00 PM is '
                      'charged per started hour; overtime has a 15-minute grace.'
                : 'Extensions and overtime are charged per started hour; '
                      'overtime has a 15-minute grace.',
            style: SrType.caption(),
          ),
          for (final occurrence in active) ...[
            const SizedBox(height: SR.space12),
            _occurrenceRow(context, occurrence, now),
          ],
          if (charges.isNotEmpty) ...[
            const SizedBox(height: SR.space12),
            Text(
              'Charges',
              style: sans(11, w: 600, color: context.srColors.ink2),
            ),
            for (final charge in charges) _chargeRow(context, charge),
          ],
          if (active.isEmpty && charges.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: SR.space8),
              child: Text(
                'No extensions or overtime recorded.',
                style: SrType.caption(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _occurrenceRow(
    BuildContext context,
    ReservationOccurrence occurrence,
    DateTime now,
  ) {
    final pending = request.pendingExtensionFor(occurrence.id);
    final over = occurrence.overtimeMinutesAt(now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${formatCampusDate(occurrence.startsAt)} · '
          '${_clock(occurrence.startsAt)}–${_clock(occurrence.endsAt)} · '
          '${occurrence.stage.label}',
          style: SrType.code(w: 500, color: context.srColors.ink3),
        ),
        if (occurrence.stage == BookingStage.checkedIn && over > 0)
          Text(
            'Running $over min over · est. '
            '${pesoFromCentavos(state.estimateExtraTimeCentavos(request, oldEnd: occurrence.endsAt, newEnd: now, overtime: true))}',
            style: SrType.caption(color: context.srColors.amberTitle),
          ),
        if (pending != null)
          Padding(
            padding: const EdgeInsets.only(top: SR.space4),
            child: Text(
              'Extension requested until '
              '${_clock(pending.newEndsAt ?? occurrence.endsAt)} · '
              '${pending.amountCentavos == 0 ? 'no charge' : pesoFromCentavos(pending.amountCentavos)}'
              '${pending.reason == null ? '' : ' · “${pending.reason}”'}',
              style: SrType.caption(color: context.srColors.amberTitle),
            ),
          ),
        const SizedBox(height: SR.space4),
        Wrap(
          spacing: SR.space8,
          runSpacing: SR.space8,
          children: [
            if (pending != null) ...[
              SrButton(
                label: 'Approve extension',
                dense: true,
                kind: SrButtonKind.success,
                onPressed: _busy
                    ? null
                    : () => state.decideExtension(
                        request,
                        pending,
                        approve: true,
                      ),
              ),
              SrButton(
                label: 'Decline',
                dense: true,
                kind: SrButtonKind.danger,
                onPressed: _busy
                    ? null
                    : () => _decline(context, pending),
              ),
            ] else if (occurrence.canRequestExtensionAt(now))
              SrButton(
                label: 'Extend',
                dense: true,
                onPressed: _busy ? null : () => _extend(context, occurrence),
              ),
            if (state.canCheckOut(request, occurrence))
              SrButton(
                label: 'Check out',
                dense: true,
                kind: SrButtonKind.primary,
                onPressed: _busy ? null : () => _checkOut(context, occurrence),
              ),
          ],
        ),
      ],
    );
  }

  Widget _chargeRow(BuildContext context, ReservationTimeCharge charge) {
    final hours = charge.billableHours;
    final detail = switch (charge.kind) {
      TimeChargeKind.extension =>
        'until ${charge.newEndsAt == null ? '—' : _clock(charge.newEndsAt!)}',
      TimeChargeKind.overtime =>
        '${charge.rawOverMinutes ?? 0} min over, checked out '
            '${charge.actualEndAt == null ? '' : _clock(charge.actualEndAt!)}',
    };
    return Padding(
      padding: const EdgeInsets.only(top: SR.space4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${charge.kind.label} · $detail · $hours '
              '${hours == 1 ? 'hr' : 'hrs'} · '
              '${pesoFromCentavos(charge.amountCentavos)} · ${charge.status.label}',
              style: SrType.caption(),
            ),
          ),
          if (charge.isBillable && charge.amountCentavos > 0)
            SrButton(
              label: 'Waive',
              dense: true,
              fontSize: 11,
              onPressed: _busy ? null : () => _waive(context, charge),
            ),
        ],
      ),
    );
  }

  Future<String?> _askReason(
    BuildContext context, {
    required String title,
    required String action,
    bool required = false,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: required ? 'Reason' : 'Reason (optional)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (required && controller.text.trim().length < 3) return;
              Navigator.pop(context, controller.text.trim());
            },
            child: Text(action),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _decline(
    BuildContext context,
    ReservationTimeCharge pending,
  ) async {
    final reason = await _askReason(
      context,
      title: 'Decline extension',
      action: 'Decline',
    );
    if (reason == null) return;
    await state.decideExtension(
      request,
      pending,
      approve: false,
      reason: reason,
    );
  }

  Future<void> _waive(BuildContext context, ReservationTimeCharge charge) async {
    final reason = await _askReason(
      context,
      title: 'Waive ${pesoFromCentavos(charge.amountCentavos)}',
      action: 'Waive charge',
      required: true,
    );
    if (reason == null) return;
    await state.waiveTimeCharge(request, charge, reason: reason);
  }

  Future<void> _extend(
    BuildContext context,
    ReservationOccurrence occurrence,
  ) async {
    var hours = 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final newEnd = occurrence.endsAt.add(Duration(hours: hours));
          final estimate = state.estimateExtraTimeCentavos(
            request,
            oldEnd: occurrence.endsAt,
            newEnd: newEnd,
          );
          return AlertDialog(
            title: const Text('Extend booking'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('+1 hr')),
                    ButtonSegment(value: 2, label: Text('+2 hrs')),
                    ButtonSegment(value: 3, label: Text('+3 hrs')),
                  ],
                  selected: {hours},
                  onSelectionChanged: (value) =>
                      setDialogState(() => hours = value.first),
                ),
                const SizedBox(height: 12),
                Text(
                  'New end ${_clock(newEnd)} · '
                  '${estimate == 0 ? 'no charge' : '${pesoFromCentavos(estimate)} added to the balance'}',
                  style: sans(12, w: 600),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Extend'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed == true) {
      await state.adminExtendOccurrence(request, occurrence, hours: hours);
    }
  }

  Future<void> _checkOut(
    BuildContext context,
    ReservationOccurrence occurrence,
  ) async {
    final now = campusNow();
    var at = now;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final over = at.isAfter(occurrence.endsAt)
              ? (at.difference(occurrence.endsAt).inSeconds / 60).ceil()
              : 0;
          final estimate = state.estimateExtraTimeCentavos(
            request,
            oldEnd: occurrence.endsAt,
            newEnd: at,
            overtime: true,
          );
          return AlertDialog(
            title: const Text('Check out'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Booked until ${_clock(occurrence.endsAt)}. Record when '
                  'the group actually left.',
                  style: sans(12, height: 1.5),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  icon: const Icon(Icons.schedule_rounded, size: 18),
                  label: Text('Checked out at ${_clock(at)}'),
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(hour: at.hour, minute: at.minute),
                    );
                    if (picked == null) return;
                    final chosen = DateTime.utc(
                      now.year,
                      now.month,
                      now.day,
                      picked.hour,
                      picked.minute,
                    );
                    // Only today, never in the future.
                    setDialogState(() => at = chosen.isAfter(now) ? now : chosen);
                  },
                ),
                const SizedBox(height: 10),
                Text(
                  over == 0
                      ? 'No overtime.'
                      : '$over min over · '
                            '${estimate == 0 ? 'within the free allowance' : 'overtime ${pesoFromCentavos(estimate)}'}',
                  style: sans(12, w: 600),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Check out'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true) return;
    // A time picked within the current minute counts as "now".
    final backdated = now.difference(at).inMinutes >= 1;
    await state.checkOutOccurrence(
      request,
      occurrence,
      checkedOutAt: backdated ? at : null,
    );
  }
}
