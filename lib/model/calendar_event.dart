import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';
import '../util/campus_calendar.dart';
import 'reservation.dart';

enum CalendarViewMode {
  month('Month'),
  week('Week'),
  day('Day');

  const CalendarViewMode(this.label);
  final String label;
}

enum CalendarEventState {
  confirmed('Confirmed', SR.divider, SR.border, SR.ink2),
  needsDecision('Needs decision', SR.amberTint, SR.amberLine, SR.amberTitle),
  changesRequested('Changes requested', SR.blueTint, SR.blueLine, SR.blueDark),
  declined('Declined', SR.redTint, SR.redLine, SR.red),
  cancelled('Cancelled', SR.dividerSoft, SR.border, SR.ink4),
  expired('Expired', SR.dividerSoft, SR.border, SR.muted);

  const CalendarEventState(
    this.label,
    this.background,
    this.border,
    this.foreground,
  );

  final String label;
  final Color background;
  final Color border;
  final Color foreground;

  static const defaultVisible = {
    CalendarEventState.confirmed,
    CalendarEventState.needsDecision,
    CalendarEventState.changesRequested,
  };
}

class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.startsAt,
    required this.endsAt,
    required this.facility,
    required this.building,
    required this.room,
    required this.requester,
    required this.organization,
    required this.purpose,
    required this.headcount,
    required this.state,
    required this.lifecycle,
    this.requestId,
    this.occurrenceId,
    this.recurrenceLabel,
    this.legacy = false,
  });

  final String id;
  final String? requestId;
  final String? occurrenceId;
  final DateTime startsAt;
  final DateTime endsAt;
  final String facility;
  final String building;
  final String room;
  final String requester;
  final String organization;
  final String purpose;
  final int headcount;
  final CalendarEventState state;
  final BookingStage lifecycle;
  final String? recurrenceLabel;
  final bool legacy;

  bool get canOpenRequest => requestId != null;

  String get timeLabel =>
      '${formatClock(startsAt.hour + startsAt.minute / 60)}–${formatClock(endsAt.hour + endsAt.minute / 60)}';

  bool overlapsDay(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return startsAt.isBefore(end) && endsAt.isAfter(start);
  }

  bool matchesQuery(String query) {
    if (query.isEmpty) return true;
    final haystack = '$facility $requester $organization $purpose'
        .toLowerCase();
    return haystack.contains(query);
  }
}
