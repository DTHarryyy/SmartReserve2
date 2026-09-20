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
  confirmed('Confirmed', SrTone.neutral),
  needsDecision('Needs decision', SrTone.warning),
  changesRequested('Changes requested', SrTone.info),
  declined('Declined', SrTone.error),
  cancelled('Cancelled', SrTone.neutral),
  expired('Expired', SrTone.neutral);

  const CalendarEventState(this.label, this.tone);

  final String label;
  final SrTone tone;

  Color get background => tone.tint;
  Color get border => tone.line;
  Color get foreground => tone.ink;

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
    this.statusLabel,
    this.summaryLabel,
    this.privacyMasked = false,
    this.isMine = false,
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
  final String? statusLabel;
  final String? summaryLabel;
  final bool privacyMasked;
  final bool isMine;

  bool get canOpenRequest => requestId != null;

  String get timeLabel =>
      '${formatClock(startsAt.hour + startsAt.minute / 60)}–${formatClock(endsAt.hour + endsAt.minute / 60)}';

  String get effectiveStatusLabel => statusLabel ?? state.label;

  String get effectiveSummaryLabel => summaryLabel ?? '$requester · $purpose';

  String get eventChipLabel => privacyMasked
      ? '$facility · $effectiveStatusLabel'
      : '$facility · $requester';

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

class PublicCalendarSlot {
  const PublicCalendarSlot({
    required this.facilityId,
    required this.startsAt,
    required this.endsAt,
    this.occurrenceId,
  });

  final String facilityId;
  final DateTime startsAt;
  final DateTime endsAt;
  final String? occurrenceId;
}
