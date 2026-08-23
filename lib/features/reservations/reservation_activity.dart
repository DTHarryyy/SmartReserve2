import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../model/audit_entry.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';

class ReservationEvent {
  const ReservationEvent({
    required this.title,
    required this.meta,
    required this.dot,
    this.note,
  });

  final String title;
  final String meta;
  final Color dot;
  final String? note;
}

List<ReservationEvent> reservationEvents(
  AppState state,
  ReservationRequest request,
) => [
  for (final entry in state.requestActivity(request.id))
    ReservationEvent(
      title: _sentence(entry.action),
      meta: '${entry.actor} · ${entry.when}',
      dot: _dotFor(entry),
      note: entry.reason.isNotEmpty
          ? entry.reason
          : (entry.diff.isEmpty ? null : entry.diff.join(' · ')),
    ),

  if (request.decidedAt != null && state.requestActivity(request.id).isEmpty)
    ReservationEvent(
      title: request.status.label,
      meta: '${request.decidedBy ?? 'the system'} · ${request.decidedAt}',
      dot: request.status.foreground,
      note: request.reason,
    ),

  if (request.heldForVerification)
    ReservationEvent(
      title: 'Legacy verification hold',
      meta: '${request.submitted} · automatic',
      dot: SR.amber,
      note:
          'This request predates snapshotted admin lanes and requires '
          'reconciliation.',
    ),

  ReservationEvent(
    title: 'Request submitted',
    meta: '${request.submitted} · ${request.requester}',
    dot: SR.blue,
    note: request.purpose,
  ),
];

Color _dotFor(AuditEntry entry) {
  final action = entry.action;
  if (action.contains('declin') || action.contains('expired')) return SR.red;
  if (action.contains('approv') || action.contains('closed')) {
    return SR.greenDark;
  }
  if (action.contains('undid') || action.contains('reopened')) return SR.muted;
  return SR.blue;
}

String _sentence(String action) =>
    action.isEmpty ? action : action[0].toUpperCase() + action.substring(1);

class ReservationActivityList extends StatelessWidget {
  const ReservationActivityList({super.key, required this.events});

  final List<ReservationEvent> events;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final event in events)
        Padding(
          padding: const EdgeInsets.only(bottom: 15),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 11,
                height: 11,
                margin: EdgeInsets.only(top: 3),
                decoration: BoxDecoration(
                  color: event.dot,
                  shape: BoxShape.circle,
                  border: Border.all(color: SR.surface, width: 3),
                  boxShadow: [BoxShadow(color: SR.hairline, spreadRadius: 1)],
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(event.title, style: sans(12, w: 600)),
                    const SizedBox(height: 2),
                    Text(event.meta, style: mono(10.5, color: SR.muted)),
                    if (event.note case final note?
                        when note.trim().isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        note,
                        style: sans(11.5, height: 1.55, color: SR.ink3),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
