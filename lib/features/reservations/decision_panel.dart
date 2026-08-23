import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../model/payment.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/rating_display.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import 'conflict_engine.dart';
import 'day_timeline.dart';
import 'payment_review_panel.dart';
import 'permit_panel.dart';
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

enum _Prompt { none, decline, changes, bump }

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
    final narrow = !context.fitsSplitView;
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);

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
                      icon: Icons.arrow_back_rounded,
                      tooltip: 'Back to the queue',
                      size: SR.controlSm,
                      onPressed: widget.onBack,
                    ),
                    const SizedBox(width: SR.space12),
                  ],
                  SrAvatar(initials: _request.initials),
                  const SizedBox(width: SR.space12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_request.requester, style: SrType.subhead()),
                        const SizedBox(height: SR.space2),
                        Text(
                          '${_request.role} · ${_request.submitted}',
                          style: SrType.caption(),
                        ),
                      ],
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(width: SR.space8),
                    SrStatusChip(
                      label: _request.lifecycleStatus.label,
                      tone: _request.lifecycleStatus.tone,
                    ),
                  ],
                ],
              ),
              if (compact) ...[
                const SizedBox(height: SR.space8),
                SrStatusChip(
                  label: _request.lifecycleStatus.label,
                  tone: _request.lifecycleStatus.tone,
                ),
              ],
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
                    label: 'PAYMENT',
                    value:
                        '${_request.aggregatePaymentStatus.label} · '
                        '${_request.outstandingAmountCentavos == 0 ? 'settled' : '${pesoFromCentavos(_request.outstandingAmountCentavos)} remaining'}',
                  ),
                  SrKeyCell(
                    label: 'AMENITIES',
                    value: _request.amenities.isEmpty
                        ? 'None requested'
                        : _request.amenities.join(' · '),
                  ),
                  SrKeyCell(
                    label: 'TERMS',
                    value: _request.acceptedTerms.isEmpty
                        ? 'No acceptance snapshot'
                        : _request.acceptedTerms
                              .map((term) => '${term.title} v${term.version}')
                              .join(' · '),
                  ),
                ],
              ),
              if (_request.recurring case final recurring?) ...[
                const SizedBox(height: SR.space8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SR.space12,
                    vertical: SR.space8,
                  ),
                  decoration: BoxDecoration(
                    color: SR.primaryTint,
                    borderRadius: BorderRadius.circular(SR.rSm),
                    border: Border.all(color: SR.primaryLine),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.repeat_rounded,
                        size: SR.iconSm,
                        color: SR.primaryDeep,
                      ),
                      const SizedBox(width: SR.space8),
                      Expanded(
                        child: Text(
                          '$recurring — one decision covers the series. Dates '
                          'that clash can be excepted rather than '
                          're-requested.',
                          style: SrType.bodySm(color: SR.primaryDeep),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_request.files.isNotEmpty) ...[
                const SizedBox(height: SR.space8),
                Wrap(
                  spacing: SR.space6,
                  runSpacing: SR.space6,
                  children: [
                    for (final file in _request.files)
                      SrButton(
                        label: file.name,
                        icon: Icon(
                          Icons.attach_file_rounded,
                          size: SR.iconSm,
                          color: SR.ink3,
                        ),
                        dense: true,
                        fontSize: 11,
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
              const SizedBox(height: SR.space16),
              Text('Purpose', style: SrType.label()),
              const SizedBox(height: SR.space4),
              Text(_request.purpose, style: SrType.body(color: SR.ink3)),
              const SizedBox(height: SR.space8),
              Text(
                '${_request.org} · ${_request.building} · ${_request.room}',
                style: SrType.caption(),
              ),
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.only(bottom: SR.space12),
          child: SrTabs(
            items: const [
              SrTabItem(label: 'Review', icon: Icons.fact_check_outlined),
              SrTabItem(label: 'Activity', icon: Icons.history_rounded),
            ],
            selectedIndex: _Tab.values.indexOf(_tab),
            onSelect: (i) => setState(() => _tab = _Tab.values[i]),
          ),
        ),

        if (_tab == _Tab.activity)
          PanelCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Activity on this reservation', style: SrType.subhead()),
                const SizedBox(height: SR.space2),
                Text(
                  'Every event on this request, most recent first.',
                  style: SrType.caption(),
                ),
                const SizedBox(height: SR.space16),
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
                  confirmed: assessment.holdsThatDay,
                ),
                if (assessment.hasConflict)
                  _request.isPending
                      ? _conflict(assessment)
                      : _overlapNotice(assessment),
              ],
            ),
          ),

          if (_series.applies) _seriesCard(),

          PanelCard(child: _actions(assessment)),

          PaymentReviewPanel(state: widget.state, request: _request),

          _eligibilityCard(),

          PermitPanel(state: widget.state, request: _request),

          if (_request.lifecycleStatus == ReservationLifecycleStatus.confirmed)
            _lifecycleCard(),

          if (_request.feedbackRating != null) _feedbackCard(),
        ],
      ],
    );
  }

  Widget _feedbackCard() => PanelCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Feedback from the requester', style: SrType.subhead()),
        const SizedBox(height: SR.space8),
        SrRatingStars(
          average: _request.feedbackRating!.toDouble(),
          count: 1,
          showCount: false,
        ),
        if (_request.feedbackComment.isNotEmpty) ...[
          const SizedBox(height: SR.space8),
          Text(_request.feedbackComment, style: SrType.body()),
        ],
      ],
    ),
  );

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
              Text('Recurring series', style: SrType.subhead()),
              const SizedBox(width: SR.space8),
              SrStatusChip(
                label: _request.cadence.toUpperCase(),
                tone: SrTone.info,
                dense: true,
              ),
            ],
          ),
          const SizedBox(height: SR.space4),
          Text(
            '${series.summary}. Approving the whole series books every date; '
            'approving with exceptions books the free dates and returns the '
            'clashing ones for a new time.',
            style: SrType.caption(),
          ),
          const SizedBox(height: SR.space12),
          Wrap(
            spacing: SR.space6,
            runSpacing: SR.space6,
            children: [
              for (final occurrence in occurrences)
                Tooltip(
                  message: occurrence.note,
                  child: Builder(
                    builder: (context) {
                      final tone = occurrence.excepted
                          ? SrTone.info
                          : (occurrence.free ? SrTone.success : SrTone.warning);
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: SR.space8,
                          vertical: SR.space4,
                        ),
                        decoration: BoxDecoration(
                          color: tone.tint,
                          borderRadius: BorderRadius.circular(SR.rSm),
                          border: Border.all(color: tone.line),
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
                              color: tone.ink,
                            ),
                            const SizedBox(width: SR.space4),
                            Text(
                              occurrence.label,
                              style: mono(10.5, w: 500, color: tone.ink),
                            ),
                          ],
                        ),
                      );
                    },
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
            const SizedBox(height: SR.space12),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: SR.space12,
                vertical: SR.space8 + 3,
              ),
              decoration: BoxDecoration(
                color: SR.primaryTint,
                borderRadius: BorderRadius.circular(SR.rSm),
                border: Border.all(color: SR.primaryLine),
              ),
              child: Text(
                '${_request.seriesExceptions.join(', ')} '
                '${_request.seriesExceptions.length == 1 ? 'was' : 'were'} '
                'handed back. The requester re-times '
                '${_request.seriesExceptions.length == 1 ? 'that date' : 'those dates'} '
                'without re-filing the series.',
                style: SrType.bodySm(color: SR.primaryDeep),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _eligibilityCard() {
    final r = _request;
    final requesterType = switch (r.paymentExemption) {
      'verified_student' => 'Verified student',
      'verified_faculty' => 'Verified faculty',
      _ => 'External / unverified',
    };
    return PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Payment and permit eligibility', style: SrType.subhead()),
          const SizedBox(height: SR.space8),
          Wrap(
            spacing: SR.space8,
            runSpacing: SR.space8,
            children: [
              SrFactChip(label: 'Requester type', value: requesterType),
              SrFactChip(
                label: 'Payment required',
                value: r.totalAmountCentavos > 0 ? 'Yes' : 'No — exempt',
              ),
              SrFactChip(
                label: 'Reservation total',
                value: pesoFromCentavos(r.totalAmountCentavos),
              ),
              if (r.totalAmountCentavos > 0) ...[
                SrFactChip(
                  label: 'Down payment policy',
                  value: '${r.downPaymentPercent}%',
                ),
                SrFactChip(
                  label: 'Down payment amount',
                  value: pesoFromCentavos(r.requiredDownPaymentCentavos),
                ),
                SrFactChip(
                  label: 'Amount paid',
                  value: pesoFromCentavos(r.verifiedAmountCentavos),
                ),
                SrFactChip(
                  label: 'Remaining balance',
                  value: pesoFromCentavos(r.outstandingAmountCentavos),
                ),
                if (r.balanceDueAt case final due?)
                  SrFactChip(
                    label: 'Payment deadline',
                    value:
                        '${_clock(campusWallTime(due))} · ${campusWallTime(due).day}/${campusWallTime(due).month}',
                  ),
              ],
              SrFactChip(
                label: 'Permit eligibility',
                value: r.permitEligible ? 'Eligible' : 'Not yet',
              ),
              SrFactChip(
                label: 'Permit status',
                value: r.permit?.status.label ?? 'Not issued',
              ),
              if (r.permit case final permit?)
                SrFactChip(label: 'Permit number', value: permit.permitNumber),
            ],
          ),
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
            Text('After the decision · each date', style: SrType.subhead()),
            const SizedBox(height: SR.space8),
            for (final occurrence in _request.occurrences)
              Padding(
                padding: const EdgeInsets.only(bottom: SR.space8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${occurrence.startsAt.day}/${occurrence.startsAt.month}/${occurrence.startsAt.year} · '
                            '${_clock(occurrence.startsAt)}–${_clock(occurrence.endsAt)}',
                            style: SrType.code(w: 500, color: SR.ink3),
                          ),
                          Text(
                            occurrence.stage.summary,
                            style: SrType.caption(),
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
          Text('After the decision', style: SrType.subhead()),
          const SizedBox(height: SR.space2),
          Text(stage.summary, style: SrType.caption()),
          const SizedBox(height: SR.space16),
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
                      color: stage.index > step.index ? SR.green : SR.divider,
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
            const SizedBox(height: SR.space12),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: SR.space12,
                vertical: SR.space8 + 3,
              ),
              decoration: BoxDecoration(
                color: SR.greenTint2,
                borderRadius: BorderRadius.circular(SR.rSm),
                border: Border.all(color: SR.greenLine),
              ),
              child: Text(
                'This booking is closed and now counts toward the utilisation '
                'report for its facility.',
                style: SrType.bodySm(color: SR.greenDark),
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
      margin: const EdgeInsets.only(top: SR.space12),
      padding: const EdgeInsets.symmetric(
        horizontal: SR.space12,
        vertical: SR.space12,
      ),
      decoration: BoxDecoration(
        color: SR.redTint,
        borderRadius: BorderRadius.circular(SR.rMd - 2),
        border: Border.all(color: SR.redLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: SR.iconSm,
                color: SR.redInk,
              ),
              const SizedBox(width: SR.space6),
              Expanded(
                child: Text(
                  kCollidesTitle,
                  style: SrType.body(w: 600, color: SR.redInk),
                ),
              ),
            ],
          ),
          const SizedBox(height: SR.space4),
          for (final conflict in assessment.conflicts)
            Text(
              '${conflict.label} · ${conflict.requester} · '
              '${conflict.start}–${conflict.end}',
              style: SrType.bodySm(color: SR.redInk2),
            ),
          const SizedBox(height: SR.space8),
          Wrap(
            spacing: SR.space6,
            runSpacing: SR.space6,
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

  Widget _overlapNotice(ReservationAssessment assessment) {
    return Container(
      margin: const EdgeInsets.only(top: SR.space12),
      padding: const EdgeInsets.symmetric(
        horizontal: SR.space12,
        vertical: SR.space12,
      ),
      decoration: BoxDecoration(
        color: SR.redTint,
        borderRadius: BorderRadius.circular(SR.rMd - 2),
        border: Border.all(color: SR.redLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: SR.iconSm,
                color: SR.redInk,
              ),
              const SizedBox(width: SR.space6),
              Expanded(
                child: Text(
                  kOverlapsFlag,
                  style: SrType.body(w: 600, color: SR.redInk),
                ),
              ),
            ],
          ),
          const SizedBox(height: SR.space4),
          for (final conflict in assessment.conflicts)
            Text(
              '${conflict.label} · ${conflict.requester} · '
              '${conflict.start}–${conflict.end}',
              style: SrType.bodySm(color: SR.redInk2),
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
            style: SrType.body(w: 500, color: SR.ink2),
          ),
          if (_request.reason case final reason?) ...[
            const SizedBox(height: SR.space8),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: SR.space12,
                vertical: SR.space8 + 3,
              ),
              decoration: BoxDecoration(
                color: SR.surfaceSubtle,
                borderRadius: BorderRadius.circular(SR.rSm),
                border: Border.all(color: SR.hairline),
              ),
              child: Text('“$reason”', style: SrType.bodySm(color: SR.ink4)),
            ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: SR.space8,
          runSpacing: SR.space8,
          children: [
            SrButton(
              label: saving ? 'Saving…' : 'Approve request',
              icon: saving
                  ? null
                  : const Icon(
                      Icons.check_rounded,
                      size: SR.iconSm,
                      color: SR.onDark,
                    ),
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
              icon: Icon(
                Icons.edit_note_rounded,
                size: SR.iconSm,
                color: SR.ink3,
              ),
              fontSize: 12.5,
              minHeight: 42,
              onPressed: saving
                  ? null
                  : () => setState(() => _prompt = _Prompt.changes),
            ),
            SrButton(
              label: 'Decline',
              icon: Icon(Icons.close_rounded, size: SR.iconSm, color: SR.red),
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
          const SizedBox(height: SR.space8),
          Align(
            alignment: Alignment.centerLeft,
            child: Hoverable(
              builder: (context, hovered) => GestureDetector(
                onTap: () => widget.state.expireRequest(_request.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SR.space12,
                    vertical: SR.space8,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(SR.rSm),
                    border: Border.all(
                      color: hovered ? SR.redLine : SR.borderField,
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: Text(
                    'No decision needed — mark expired',
                    style: SrType.caption(
                      w: 500,
                      color: hovered ? SR.red : SR.muted,
                    ),
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
            ? Icon(Icons.check_rounded, size: 12, color: SR.greenDark)
            : Text('$index', style: mono(9.5, w: 600, color: SR.muted)),
      ),
      const SizedBox(width: 7),
      Text(label, style: sans(11, w: 500, color: done ? SR.ink2 : SR.muted)),
    ],
  );
}
