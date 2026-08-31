library;

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../model/account.dart';
import '../../model/amenity_request.dart';
import '../../model/facility.dart';
import '../../model/notice.dart';
import '../../model/payment.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/amenity_request_field.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_logo.dart';
import 'assistant_availability.dart';
import 'assistant_controller.dart';

import '../../theme/sr_theme.dart';

class AssistantBubble extends StatelessWidget {
  const AssistantBubble({super.key, required this.message});

  final AssistantMessage message;

  static const _tail = Radius.circular(4);
  static const _round = Radius.circular(18);

  @override
  Widget build(BuildContext context) {
    if (message.text.isEmpty || message.kind == AssistantMessageKind.activity) {
      return const SizedBox.shrink();
    }
    final isUser = message.speaker == AssistantSpeaker.user;
    final Color bg;
    final Color? border;
    final Color ink;
    if (isUser) {
      bg = context.srColors.brand;
      border = null;
      ink = SR.onDark;
    } else if (message.tone == AdvisoryTone.block) {
      bg = context.srColors.redTint;
      border = context.srColors.redLine;
      ink = context.srColors.ink2;
    } else if (message.tone == AdvisoryTone.warn) {
      bg = context.srColors.amberTint;
      border = context.srColors.amberLine;
      ink = context.srColors.ink2;
    } else {
      bg = context.srColors.surface;
      border = context.srColors.border;
      ink = context.srColors.ink2;
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
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            const Padding(
              padding: EdgeInsets.only(right: 7, bottom: 2),
              child: SrLogo(size: 26, radius: 13),
            ),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                bubble,
                const SizedBox(height: 3),
                Text(
                  '${message.createdAt.hour.toString().padLeft(2, '0')}:${message.createdAt.minute.toString().padLeft(2, '0')}',
                  style: mono(9.5, color: context.srColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AssistantActivityCard extends StatelessWidget {
  const AssistantActivityCard({super.key, required this.message});

  final AssistantMessage message;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    ReservationRequest? linked;
    for (final request in state.myRequests) {
      if (request.id == message.reservationId) {
        linked = request;
        break;
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: context.srColors.successContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.srColors.greenLine),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 17,
                  color: context.srColors.success,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    message.text,
                    style: sans(
                      11.5,
                      w: 500,
                      color: context.srColors.greenDeep,
                    ),
                  ),
                ),
              ],
            ),
            if (linked != null) ...[
              const SizedBox(height: 8),
              SrPill(
                label: 'Current status: ${linked.status.label}',
                background: linked.status.background,
                foreground: linked.status.foreground,
              ),
            ],
          ],
        ),
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
          Text(
            facility.whereLine,
            style: sans(11, color: context.srColors.muted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              SrPill(
                label: '${facility.capacity} seats',
                background: context.srColors.dividerSoft,
                foreground: context.srColors.ink3,
              ),
              SrPill(
                label: facility.hours,
                background: context.srColors.dividerSoft,
                foreground: context.srColors.ink3,
                monospace: true,
              ),
              SrPill(
                label: facility.days,
                background: context.srColors.dividerSoft,
                foreground: context.srColors.ink3,
              ),
              for (final amenity in facility.amenities.take(4))
                SrPill(
                  label: amenity,
                  background: context.srColors.primaryTint2,
                  foreground: context.srColors.primaryDeep,
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
                  style: mono(11, color: context.srColors.ink4),
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
          Text(
            request.whenLabel,
            style: sans(11.5, color: context.srColors.ink4),
          ),
          const SizedBox(height: 3),
          Text(
            '${request.heads} people',
            style: sans(11, color: context.srColors.muted),
          ),
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
    final requestedAmenities = normalizeRequestedAmenityLabels(
      facility,
      draft.amenities,
    );
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
                  value: requestedAmenities.isEmpty
                      ? 'None'
                      : requestedAmenities.join(' · '),
                ),
              ],
            ),
            if (draft.purpose != null && draft.purpose!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('PURPOSE', style: keyLabel),
              const SizedBox(height: 4),
              Text(
                draft.purpose!,
                style: sans(12.5, height: 1.5, color: context.srColors.ink2),
              ),
            ],
            const SizedBox(height: 10),
            AmenityRequestField(
              dense: true,
              includedAmenities: includedFacilityAmenities(facility),
              requestableAmenities: requestableAmenityLabels(facility),
              selectedRequestedAmenities: requestedAmenities.toSet(),
              onToggle: controller.toggleDraftAmenity,
              onRemove: controller.removeDraftAmenity,
            ),
            if (facility.approvalRequired || pending) ...[
              const SizedBox(height: 10),
              SrPill(
                label: pending
                    ? 'Uses the guest/unverified admin lane'
                    : 'Needs facility administrator approval',
                background: context.srColors.amberTint,
                foreground: context.srColors.amberTitle,
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
                          controller.confirm(state).whenComplete(() {
                            controller.syncHistory();
                          });
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
