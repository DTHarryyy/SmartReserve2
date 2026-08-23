library;

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/account.dart';
import '../../model/facility.dart';
import '../../model/notice.dart';
import '../../model/payment.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/amenity_request_field.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/sr_controls.dart';
import 'assistant_availability.dart';
import 'assistant_controller.dart';

class AssistantBubble extends StatelessWidget {
  const AssistantBubble({super.key, required this.message});

  final AssistantMessage message;

  static const _tail = Radius.circular(4);
  static const _round = Radius.circular(18);

  @override
  Widget build(BuildContext context) {
    if (message.text.isEmpty) return const SizedBox.shrink();
    final isUser = message.speaker == AssistantSpeaker.user;
    final Color bg;
    final Color? border;
    final Color ink;
    if (isUser) {
      bg = SR.blue;
      border = null;
      ink = SR.onDark;
    } else if (message.tone == AdvisoryTone.block) {
      bg = SR.redTint;
      border = SR.redLine;
      ink = SR.ink2;
    } else if (message.tone == AdvisoryTone.warn) {
      bg = SR.amberTint;
      border = SR.amberLine;
      ink = SR.ink2;
    } else {
      bg = SR.surface;
      border = SR.border;
      ink = SR.ink2;
    }

    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.only(
          topLeft: _round,
          topRight: _round,
          bottomLeft: isUser ? _round : _tail,
          bottomRight: isUser ? _tail : _round,
        ),
        border: border == null ? null : Border.all(color: border),
      ),
      child: Text(
        message.text,
        maxLines: 12,
        overflow: TextOverflow.ellipsis,
        style: sans(13.5, height: 1.45, color: ink),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [Flexible(child: bubble)],
      ),
    );
  }
}

class AssistantChipRow extends StatelessWidget {
  const AssistantChipRow({super.key, required this.chips, required this.state});

  final List<AssistantChipOption> chips;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final chip in chips)
            FilterPill(
              label: chip.label,
              selected: false,
              onTap: () => chip.onSelect(state),
            ),
        ],
      ),
    );
  }
}

class AssistantFacilityCard extends StatelessWidget {
  const AssistantFacilityCard({super.key, required this.facility, this.onBook});

  final Facility facility;
  final VoidCallback? onBook;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return PanelCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  facility.name,
                  style: sans(13, w: 600, tracking: -.01),
                ),
              ),
              const SizedBox(width: 8),
              SrPill(
                label: facility.state.label,
                background: facility.state.background,
                foreground: facility.state.foreground,
                dot: facility.state.dot,
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(facility.whereLine, style: sans(11, color: SR.muted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              SrPill(
                label: '${facility.capacity} seats',
                background: SR.dividerSoft,
                foreground: SR.ink3,
              ),
              SrPill(
                label: facility.hours,
                background: SR.dividerSoft,
                foreground: SR.ink3,
                monospace: true,
              ),
              SrPill(
                label: facility.days,
                background: SR.dividerSoft,
                foreground: SR.ink3,
              ),
              for (final amenity in facility.amenities.take(4))
                SrPill(
                  label: amenity,
                  background: SR.blueTint2,
                  foreground: SR.blueInk,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  facility.hourlyRateCentavosFor(
                            state.userAccount.pricingAudience,
                          ) ==
                          0
                      ? 'Included for your audience'
                      : '${pesoFromCentavos(facility.hourlyRateCentavosFor(state.userAccount.pricingAudience) * 2)} / 2h',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono(11, color: SR.ink4),
                ),
              ),
              if (onBook != null &&
                  facility.state != FacilityState.maintenance) ...[
                const SizedBox(width: 8),
                SrButton(
                  label: 'Book this',
                  kind: SrButtonKind.primary,
                  dense: true,
                  fontSize: 11,
                  onPressed: onBook,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class AssistantFacilityListView extends StatelessWidget {
  const AssistantFacilityListView({
    super.key,
    required this.facilities,
    required this.controller,
  });

  final List<Facility> facilities;
  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final facility in facilities)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AssistantFacilityCard(
                facility: facility,
                onBook: () {
                  controller.chooseFacility(facility, state);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class AssistantReservationCard extends StatelessWidget {
  const AssistantReservationCard({
    super.key,
    required this.request,
    required this.controller,
  });

  final ReservationRequest request;
  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final cancellable = state.canCancelReservation(request);
    final cancelling = state.reservationActionsPending.contains(request.id);
    return PanelCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(request.facility, style: sans(13, w: 600))),
              const SizedBox(width: 8),
              SrPill(
                label: request.status.label,
                background: request.status.background,
                foreground: request.status.foreground,
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(request.whenLabel, style: sans(11.5, color: SR.ink4)),
          const SizedBox(height: 3),
          Text('${request.heads} people', style: sans(11, color: SR.muted)),
          if (request.amenities.isNotEmpty) ...[
            const SizedBox(height: 6),
            AmenityPills(request.amenities, max: 4),
          ],
          if (cancellable) ...[
            const SizedBox(height: 8),
            SrButton(
              label: cancelling ? 'Cancelling…' : 'Cancel',
              kind: SrButtonKind.danger,
              dense: true,
              fontSize: 11,
              onPressed: cancelling
                  ? null
                  : () async {
                      final cancelled = await state.cancelReservation(
                        request,
                        reason: 'Cancelled from the assistant',
                      );
                      if (cancelled) controller.noteCancelled(request);
                    },
            ),
          ],
        ],
      ),
    );
  }
}

class AssistantReservationListView extends StatelessWidget {
  const AssistantReservationListView({
    super.key,
    required this.reservations,
    required this.controller,
  });

  final List<ReservationRequest> reservations;
  final AssistantController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in reservations)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AssistantReservationCard(request: r, controller: controller),
          ),
      ],
    ),
  );
}

class AssistantConfirmCard extends StatelessWidget {
  const AssistantConfirmCard({super.key, required this.controller});

  final AssistantController controller;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final draft = controller.draft;
    final facility = draft.facility;
    if (facility == null || draft.day == null || !draft.hasTime) {
      return const SizedBox.shrink();
    }
    final hours = draft.endHour! - draft.startHour!;
    final quoteCentavos =
        (facility.hourlyRateCentavosFor(state.userAccount.pricingAudience) *
                hours)
            .round();
    final pending = state.userAccount.verification == VerificationState.pending;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: PanelCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ready to send', style: sans(13, w: 600, tracking: -.01)),
            const SizedBox(height: 10),
            SrCellGrid(
              columns: 2,
              children: [
                SrKeyCell(label: 'FACILITY', value: facility.name),
                SrKeyCell(
                  label: 'WHEN',
                  value:
                      '${formatCampusDate(draft.day!)} · '
                      '${formatClockHour(draft.startHour!)}–${formatClockHour(draft.endHour!)}',
                ),
                SrKeyCell(label: 'PEOPLE', value: '${draft.heads ?? '-'}'),
                SrKeyCell(
                  label: 'COST',
                  value: quoteCentavos == 0
                      ? 'Included rate'
                      : pesoFromCentavos(quoteCentavos),
                ),
                SrKeyCell(
                  label: 'AMENITIES',
                  value: draft.amenities.isEmpty
                      ? 'None'
                      : draft.amenities.join(' · '),
                ),
              ],
            ),
            if (draft.purpose != null && draft.purpose!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('PURPOSE', style: keyLabel),
              const SizedBox(height: 4),
              Text(
                draft.purpose!,
                style: sans(12.5, height: 1.5, color: SR.ink2),
              ),
            ],
            const SizedBox(height: 10),
            AmenityRequestField(
              dense: true,
              facilityAmenities: facility.amenities,
              amenityOptions: facility.amenityOptions,
              selected: draft.amenities,
              onToggle: controller.toggleDraftAmenity,
              onRemove: controller.removeDraftAmenity,
            ),
            if (facility.approvalRequired || pending) ...[
              const SizedBox(height: 10),
              SrPill(
                label: pending
                    ? 'Uses the guest/unverified admin lane'
                    : 'Needs facility administrator approval',
                background: SR.amberTint,
                foreground: SR.amberTitle,
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                SrButton(
                  label: controller.submitting ? 'Sending…' : 'Confirm request',
                  kind: SrButtonKind.primary,
                  onPressed: controller.submitting
                      ? null
                      : () {
                          controller.confirm(state);
                        },
                ),
                const SizedBox(width: 8),
                SrButton(
                  label: 'Cancel',
                  kind: SrButtonKind.ghost,
                  onPressed: controller.submitting
                      ? null
                      : () {
                          controller.discardDraft();
                        },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
