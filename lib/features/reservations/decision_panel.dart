import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/sr_controls.dart';
import 'day_timeline.dart';
import 'reservation_activity.dart';
import 'reservation_checks.dart';
import 'reservation_series.dart';

class DecisionPanel extends StatefulWidget {
  const DecisionPanel({
    super.key,
    required this.state,
    required this.assessment,
    required this.showBack,
    required this.onBack,
  });

  final AppState state;
  final ReservationAssessment assessment;
  final bool showBack;
  final VoidCallback onBack;

  @override
  State<DecisionPanel> createState() => _DecisionPanelState();
}

enum _Prompt { none, decline, changes, bump, reopen }

enum _Tab { review, activity }

class _DecisionPanelState extends State<DecisionPanel> {
  _Prompt _prompt = _Prompt.none;
  _Tab _tab = _Tab.review;

  @override
  void didUpdateWidget(DecisionPanel old) {
    super.didUpdateWidget(old);

    if (old.assessment.request.id != widget.assessment.request.id) {
      _prompt = _Prompt.none;
      _tab = _Tab.review;
    }
  }

  ReservationRequest get _request => widget.assessment.request;

  ReservationSeries get _series => ReservationSeries(
    request: _request,
    bookings: widget.state.bookings,
    otherRequests: widget.state.requests,
  );

  @override
  Widget build(BuildContext context) {
    final assessment = widget.assessment;
    final facility = assessment.facility;
    final narrow = MediaQuery.sizeOf(context).width < 900;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.showBack) ...[
                    SrIconButton(
                      glyph: '←',
                      tooltip: 'Back to the queue',
                      size: 32,
                      fontSize: 13,
                      onPressed: widget.onBack,
                    ),
                    const SizedBox(width: 12),
                  ],
                  Initials(text: _request.initials),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _request.requester,
                          style: sans(14.5, w: 600, tracking: -.015),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_request.role} · ${_request.submitted}',
                          style: sans(11.5, color: SR.ink4),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SrPill(
                    label: _request.status.label,
                    background: _request.status.background,
                    foreground: _request.status.foreground,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SrCellGrid(
                columns: narrow ? 1 : 2,
                children: [
                  SrKeyCell(label: 'FACILITY', value: _request.facility),
                  SrKeyCell(
                    label: 'REQUESTED SLOT',
                    value: _request.whenLabel,
                    valueMono: true,
                  ),
                  SrKeyCell(
                    label: 'HEADCOUNT',
                    value:
                        '${_request.heads} of '
                        '${facility?.capacity ?? _request.capacity} seats',
                    valueColor: _request.overCapacity ? SR.red : SR.ink,
                  ),
                  SrKeyCell(
                    label: 'SUPPORTING FILES',
                    value: _request.attachments == 0
                        ? 'None attached'
                        : '${_request.attachments} attached',
                  ),
                  SrKeyCell(
                    label: 'PAYMENT TRACKING',
                    value: _request.paymentStatus.label,
                  ),
                ],
              ),
              if (_request.recurring case final recurring?) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: SR.blueTint,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: SR.blueLine),
                  ),
                  child: Text(
                    '$recurring — one decision covers the series. Dates that '
                    'clash can be excepted rather than re-requested.',
                    style: sans(11.5, height: 1.5, color: SR.blueInk),
                  ),
                ),
              ],
              if (_request.files.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final file in _request.files)
                      SrButton(
                        label: file.name,
                        dense: true,
                        fontSize: 10.5,
                        onPressed: () async {
                          final url = await widget.state
                              .reservationAttachmentUrl(file);
                          if (url != null) {
                            await launchUrl(
                              Uri.parse(url),
                              mode: LaunchMode.externalApplication,
                            );
                          }
                        },
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Text('Purpose', style: sans(11, w: 500, color: SR.ink2)),
              const SizedBox(height: 4),
              Text(
                _request.purpose,
                style: sans(12.5, height: 1.65, color: SR.ink3),
              ),
              const SizedBox(height: 6),
              Text(
                '${_request.org} · ${_request.building} · ${_request.room}',
                style: sans(11, color: SR.muted),
              ),
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: SR.surface,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: SR.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final tab in _Tab.values)
                    _PanelTab(
                      label: tab == _Tab.review ? 'Review' : 'Activity',
                      selected: _tab == tab,
                      onTap: () => setState(() => _tab = tab),
                    ),
                ],
              ),
            ),
          ),
        ),

        if (_tab == _Tab.activity)
          PanelCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Activity on this reservation', style: sans(12.5, w: 600)),
                const SizedBox(height: 2),
                Text(
                  'Every event on this request, most recent first.',
                  style: sans(11, color: SR.muted),
                ),
                const SizedBox(height: 14),
                ReservationActivityList(
                  events: reservationEvents(widget.state, _request),
                ),
              ],
            ),
          )
        else ...[
          PanelCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CheckList(
                  summary: assessment.summary,
                  checks: assessment.checks,
                ),
                const SizedBox(height: 14),
                Text(
                  'That day in ${_request.facility}',
                  style: sans(11, w: 500, color: SR.ink2),
                ),
                const SizedBox(height: 8),
                DayTimeline(
                  assessment: assessment,
                  confirmed: [
                    for (final b in widget.state.bookings)
                      if (b.facility == _request.facility &&
                          b.date == _request.date)
                        b,
                  ],
                ),
                if (assessment.hasConflict) _conflict(assessment),
              ],
            ),
          ),

          if (_series.applies) _seriesCard(),

          PanelCard(child: _actions(assessment)),

          if (_request.status == RequestStatus.approved) _lifecycleCard(),
        ],
      ],
    );
  }

  Widget _seriesCard() {
    final series = _series;
    final occurrences = series.occurrences;
    final free = series.free;
    final clashing = series.clashing;
    final decided = !_request.isPending;

    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Recurring series', style: sans(12.5, w: 600)),
              const SizedBox(width: 8),
              SrPill(
                label: _request.cadence.toUpperCase(),
                background: SR.blueTint,
                foreground: SR.blueDark,
                monospace: true,
                fontSize: 9.5,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${series.summary}. Approving the whole series books every date; '
            'approving with exceptions books the free dates and returns the '
            'clashing ones for a new time.',
            style: sans(11, height: 1.55, color: SR.ink4),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final occurrence in occurrences)
                Tooltip(
                  message: occurrence.note,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: occurrence.excepted
                          ? SR.blueTint
                          : (occurrence.free ? SR.greenTint : SR.amberTint),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: occurrence.excepted
                            ? SR.blueLine
                            : (occurrence.free
                                  ? const Color(0xFFB7E9CD)
                                  : SR.amberLine),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          occurrence.excepted
                              ? Icons.undo_rounded
                              : (occurrence.free
                                    ? Icons.check_rounded
                                    : Icons.warning_amber_rounded),
                          size: 11,
                          color: occurrence.excepted
                              ? SR.blueDark
                              : (occurrence.free ? SR.greenDark : SR.amber),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          occurrence.label,
                          style: mono(
                            10.5,
                            w: 500,
                            color: occurrence.excepted
                                ? SR.blueDark
                                : (occurrence.free ? SR.greenDark : SR.amber),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (!decided) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SrButton(
                  label: 'Approve whole series',
                  kind: SrButtonKind.success,
                  fontSize: 12,
                  minHeight: 40,
                  onPressed: () => widget.state.approveSeries(_request.id, [
                    for (final o in occurrences) o.label,
                  ]),
                ),
                if (clashing.isNotEmpty)
                  SrButton(
                    label: 'Approve ${free.length}, return ${clashing.length}',
                    kind: SrButtonKind.caution,
                    fontSize: 12,
                    minHeight: 40,
                    onPressed: () => widget.state.approveSeriesWithExceptions(
                      _request.id,
                      booked: [for (final o in free) o.label],
                      excepted: [for (final o in clashing) o.label],
                    ),
                  ),
              ],
            ),
          ],
          if (_request.seriesExceptions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: SR.blueTint,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: SR.blueLine),
              ),
              child: Text(
                '${_request.seriesExceptions.join(', ')} '
                '${_request.seriesExceptions.length == 1 ? 'was' : 'were'} '
                'handed back. The requester re-times '
                '${_request.seriesExceptions.length == 1 ? 'that date' : 'those dates'} '
                'without re-filing the series.',
                style: sans(11.5, height: 1.55, color: SR.blueInk),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _lifecycleCard() {
    if (_request.occurrences.length > 1) {
      return PanelCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('After the decision · each date', style: sans(12.5, w: 600)),
            const SizedBox(height: 10),
            for (final occurrence in _request.occurrences)
              Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${occurrence.startsAt.day}/${occurrence.startsAt.month}/${occurrence.startsAt.year} · '
                            '${_clock(occurrence.startsAt)}–${_clock(occurrence.endsAt)}',
                            style: mono(10.5, w: 500, color: SR.ink3),
                          ),
                          Text(
                            occurrence.stage.summary,
                            style: sans(10.5, color: SR.muted),
                          ),
                        ],
                      ),
                    ),
                    if (occurrence.isBooked &&
                        occurrence.stage == BookingStage.booked) ...[
                      SrButton(
                        label: 'Check in',
                        dense: true,
                        onPressed:
                            campusNow().isBefore(
                              occurrence.startsAt.subtract(
                                const Duration(minutes: 30),
                              ),
                            )
                            ? null
                            : () => widget.state.advanceOccurrenceStage(
                                _request,
                                occurrence,
                                BookingStage.checkedIn,
                              ),
                      ),
                      const SizedBox(width: 5),
                      SrButton(
                        label: 'No-show',
                        dense: true,
                        kind: SrButtonKind.danger,
                        onPressed:
                            campusNow().isBefore(
                              occurrence.startsAt.add(
                                const Duration(minutes: 15),
                              ),
                            )
                            ? null
                            : () => widget.state.advanceOccurrenceStage(
                                _request,
                                occurrence,
                                BookingStage.noShow,
                              ),
                      ),
                    ] else if (occurrence.stage == BookingStage.checkedIn)
                      SrButton(
                        label: 'Complete',
                        dense: true,
                        kind: SrButtonKind.success,
                        onPressed: () => widget.state.advanceOccurrenceStage(
                          _request,
                          occurrence,
                          BookingStage.completed,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    }
    final stage = _request.stage;
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('After the decision', style: sans(12.5, w: 600)),
          const SizedBox(height: 2),
          Text(stage.summary, style: sans(11, color: SR.muted)),
          const SizedBox(height: 14),
          Row(
            children: [
              for (final step in BookingStage.values) ...[
                _StageDot(
                  label: step.label,
                  index: step.index + 1,
                  done: stage.index >= step.index,
                ),
                if (step != BookingStage.completed)
                  Container(
                    width: 22,
                    height: 2,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: stage.index > step.index
                          ? SR.greenDark
                          : SR.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
              ],
            ],
          ),
          if (stage != BookingStage.completed &&
              stage != BookingStage.noShow) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: SrButton(
                label: stage == BookingStage.booked
                    ? 'Check in attendees'
                    : 'Mark completed',

                kind: stage == BookingStage.booked
                    ? SrButtonKind.primary
                    : SrButtonKind.success,
                fontSize: 12,
                minHeight: 40,
                onPressed: () => widget.state.advanceStage(
                  _request.id,
                  stage == BookingStage.booked
                      ? BookingStage.checkedIn
                      : BookingStage.completed,
                ),
              ),
            ),
            if (stage == BookingStage.booked &&
                _request.occurrences.isNotEmpty &&
                campusNow().isAfter(
                  _request.occurrences.first.startsAt.add(
                    const Duration(minutes: 15),
                  ),
                )) ...[
              const SizedBox(height: 7),
              Align(
                alignment: Alignment.centerLeft,
                child: SrButton(
                  label: 'Mark no-show',
                  kind: SrButtonKind.danger,
                  dense: true,
                  onPressed: () => widget.state.advanceOccurrenceStage(
                    _request,
                    _request.occurrences.first,
                    BookingStage.noShow,
                  ),
                ),
              ),
            ],
          ] else ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: const Color(0xFFF2FDF7),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: const Color(0xFFB7E9CD)),
              ),
              child: Text(
                'This booking is closed and now counts toward the utilisation '
                'report for its facility.',
                style: sans(11.5, height: 1.55, color: SR.greenDark),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _clock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  Widget _conflict(ReservationAssessment assessment) {
    final next = assessment.nextFreeSlot;
    return Container(
      margin: const EdgeInsets.only(top: 13),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color: SR.redTint,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SR.redLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Collides with an existing booking',
            style: sans(12, w: 600, color: const Color(0xFF912018)),
          ),
          const SizedBox(height: 3),
          for (final conflict in assessment.conflicts)
            Text(
              '${conflict.label} · ${conflict.requester} · '
              '${conflict.start}–${conflict.end}',
              style: sans(11.5, height: 1.55, color: const Color(0xFFA4413A)),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              if (next != null)
                SrButton(
                  label: 'Offer ${next.start}–${next.end} instead',
                  kind: SrButtonKind.dangerSolid,
                  dense: true,
                  fontSize: 11,
                  onPressed: () => widget.state.offerAlternativeSlot(
                    _request.id,
                    next.start,
                    next.end,
                  ),
                ),
              SrButton(
                label: 'Approve and bump existing',
                kind: SrButtonKind.danger,
                dense: true,
                fontSize: 11,
                onPressed: () => setState(() => _prompt = _Prompt.bump),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actions(ReservationAssessment assessment) {
    final saving = widget.state.reservationActionsPending.contains(_request.id);
    if (!_request.isPending) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_request.status.label} by ${_request.decidedBy ?? 'the system'}'
            '${_request.decidedAt == null ? '' : ' · ${_request.decidedAt}'}',
            style: sans(12, w: 500, color: SR.ink2),
          ),
          if (_request.reason case final reason?) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: SR.surfaceSubtle,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: SR.hairline),
              ),
              child: Text(
                '“$reason”',
                style: sans(11.5, height: 1.6, color: SR.ink4),
              ),
            ),
          ],
          const SizedBox(height: 12),
          SrButton(
            label: saving ? 'Saving…' : 'Reopen for decision',
            onPressed: saving
                ? null
                : () => setState(() => _prompt = _Prompt.reopen),
          ),
          if (_prompt == _Prompt.reopen)
            ReasonBox(
              tone: ReasonTone.neutral,
              title: 'Why this reservation is being reopened',
              placeholder:
                  'Explain what changed and what must be reviewed again.',
              confirmLabel: 'Reopen for decision',
              onCancel: () => setState(() => _prompt = _Prompt.none),
              onConfirm: (reason) {
                setState(() => _prompt = _Prompt.none);
                widget.state.decideRequest(
                  _request.id,
                  RequestStatus.pending,
                  reason: reason,
                  announce: false,
                );
              },
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SrButton(
              label: saving ? 'Saving…' : 'Approve request',
              kind: SrButtonKind.primary,
              fontSize: 12.5,
              minHeight: 42,
              onPressed:
                  saving || assessment.hasConflict || _request.overCapacity
                  ? null
                  : () => widget.state.decideRequest(
                      _request.id,
                      RequestStatus.approved,
                    ),
            ),
            SrButton(
              label: 'Request changes',
              fontSize: 12.5,
              minHeight: 42,
              onPressed: saving
                  ? null
                  : () => setState(() => _prompt = _Prompt.changes),
            ),
            SrButton(
              label: 'Decline',
              kind: SrButtonKind.danger,
              fontSize: 12.5,
              minHeight: 42,
              onPressed: saving
                  ? null
                  : () => setState(() => _prompt = _Prompt.decline),
            ),
          ],
        ),

        if (widget.state.canExpire(_request)) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Hoverable(
              builder: (context, hovered) => GestureDetector(
                onTap: () => widget.state.expireRequest(_request.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: hovered ? SR.redLine : SR.borderField,
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: Text(
                    'No decision needed — mark expired',
                    style: sans(11, w: 500, color: hovered ? SR.red : SR.muted),
                  ),
                ),
              ),
            ),
          ),
        ],
        if (_prompt == _Prompt.decline)
          ReasonBox(
            title: 'Reason for declining',
            placeholder:
                'The requester sees this verbatim, so be specific and suggest '
                'a way forward.',
            confirmLabel: 'Decline and notify',
            onCancel: () => setState(() => _prompt = _Prompt.none),
            onConfirm: (reason) {
              setState(() => _prompt = _Prompt.none);
              widget.state.decideRequest(
                _request.id,
                RequestStatus.declined,
                reason: reason,
              );
            },
          ),
        if (_prompt == _Prompt.changes)
          ReasonBox(
            tone: ReasonTone.neutral,
            title: 'What needs to change',
            placeholder:
                'e.g. Move to 13:00 and the room is free, or attach the '
                'adviser\'s endorsement.',
            confirmLabel: 'Send change request',
            onCancel: () => setState(() => _prompt = _Prompt.none),
            onConfirm: (reason) {
              setState(() => _prompt = _Prompt.none);
              widget.state.decideRequest(
                _request.id,
                RequestStatus.changesRequested,
                reason: reason,
              );
            },
          ),
        if (_prompt == _Prompt.bump)
          ReasonBox(
            title: 'Why the existing booking is being bumped',
            placeholder:
                'Both parties are notified with this reason, so it has to '
                'stand on its own.',
            confirmLabel: 'Approve and bump',
            onCancel: () => setState(() => _prompt = _Prompt.none),
            onConfirm: (reason) {
              setState(() => _prompt = _Prompt.none);
              widget.state.bumpFor(_request.id, reason);
            },
          ),
      ],
    );
  }
}

class _PanelTab extends StatelessWidget {
  const _PanelTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SR.stateChange,
          constraints: BoxConstraints(
            minHeight: SR.isCompact(MediaQuery.sizeOf(context).width) ? 44 : 0,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? SR.ink
                : (hovered ? SR.dividerSoft : Colors.transparent),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            label,
            style: sans(12, w: 500, color: selected ? SR.surface : SR.ink4),
          ),
        ),
      ),
    ),
  );
}

class _StageDot extends StatelessWidget {
  const _StageDot({
    required this.label,
    required this.index,
    required this.done,
  });

  final String label;
  final int index;
  final bool done;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: done ? SR.greenTint : SR.dividerSoft,
          shape: BoxShape.circle,
        ),
        child: done
            ? const Icon(Icons.check_rounded, size: 12, color: SR.greenDark)
            : Text('$index', style: mono(9.5, w: 600, color: SR.muted)),
      ),
      const SizedBox(width: 7),
      Text(label, style: sans(11, w: 500, color: done ? SR.ink2 : SR.muted)),
    ],
  );
}
