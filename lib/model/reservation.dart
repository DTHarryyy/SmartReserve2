import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';

enum BookingStage {
  booked('Approved', 'Approved — the room is held and the requester notified.'),
  checkedIn('Checked in', 'Checked in — attendees are in the room.'),
  completed('Completed', 'Completed and closed.'),
  noShow('No-show', 'The requester did not check in before the grace period ended.');

  const BookingStage(this.label, this.summary);

  final String label;
  final String summary;

  bool operator >=(BookingStage other) => index >= other.index;
}

enum RequestStatus {
  pending('pending', 'Needs decision', SR.amberTint, SR.amber),
  approved('approved', 'Approved', SR.greenTint, SR.greenDark),
  declined('declined', 'Declined', SR.redTint, SR.red),
  changesRequested('changes', 'Changes requested', SR.blueTint, SR.blueDark),
  cancelled('cancelled', 'Cancelled', SR.dividerSoft, SR.ink4),
  expired('expired', 'Expired', SR.dividerSoft, SR.muted);

  const RequestStatus(this.raw, this.label, this.background, this.foreground);

  final String raw;
  final String label;
  final Color background;
  final Color foreground;

  static RequestStatus fromRaw(String raw) => values.firstWhere(
    (s) => s.raw == raw ||
        (s == RequestStatus.changesRequested && raw == 'changes_requested'),
    orElse: () => RequestStatus.pending,
  );
}

enum PaymentTrackingStatus {
  notRequired('not_required', 'No payment required'),
  quoted('quoted', 'Quoted — tracking only'),
  authorized('authorized', 'Authorised — tracking only'),
  captured('captured', 'Captured — tracking only'),
  voided('voided', 'Voided — tracking only');

  const PaymentTrackingStatus(this.raw, this.label);
  final String raw;
  final String label;

  static PaymentTrackingStatus fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => PaymentTrackingStatus.notRequired,
  );
}

class ReservationOccurrence {
  const ReservationOccurrence({
    required this.id,
    required this.startsAt,
    required this.endsAt,
    this.bookingState = 'requested',
    this.stage = BookingStage.booked,
    this.proposedStartsAt,
    this.proposedEndsAt,
    this.reason,
  });

  final String id;
  final DateTime startsAt;
  final DateTime endsAt;
  final String bookingState;
  final BookingStage stage;
  final DateTime? proposedStartsAt;
  final DateTime? proposedEndsAt;
  final String? reason;

  bool get isBooked => bookingState == 'booked';
  bool get needsNewTime => bookingState == 'changes_requested' || bookingState == 'bumped';
}

class ReservationFile {
  const ReservationFile({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.byteSize,
    required this.storagePath,
  });

  final String id;
  final String name;
  final String mimeType;
  final int byteSize;
  final String storagePath;
}

class ReservationRequest {
  ReservationRequest({
    required this.id,
    required this.facility,
    required this.building,
    required this.room,
    required this.capacity,
    required this.requester,
    required this.role,
    required this.org,
    required this.purpose,
    required this.date,
    required this.start,
    required this.end,
    required this.heads,
    required this.submitted,
    required this.urgent,
    required this.attachments,
    required this.noShows,
    required this.status,
    this.recurring,
    this.decidedBy,
    this.decidedAt,
    this.reason,
    this.heldForVerification = false,
    this.stage = BookingStage.booked,
    List<String>? seriesExceptions,
    this.requesterId,
    this.facilityId,
    this.version = 1,
    this.paymentAmountCentavos = 0,
    this.paymentStatus = PaymentTrackingStatus.notRequired,
    List<ReservationOccurrence>? occurrences,
    List<ReservationFile>? files,
  }) : seriesExceptions = seriesExceptions ?? <String>[],
       occurrences = occurrences ?? <ReservationOccurrence>[],
       files = files ?? <ReservationFile>[];

  final String id;
  final String? requesterId;
  final String? facilityId;
  final String facility;
  final String building;
  final String room;
  final int capacity;
  final String requester;
  final String role;
  final String org;
  final String purpose;

  final String date;

  String start;
  String end;
  final int heads;

  final String submitted;
  final bool urgent;
  final int attachments;

  final String? recurring;

  final int noShows;

  RequestStatus status;
  String? decidedBy;
  String? decidedAt;
  String? reason;

  bool heldForVerification;

  BookingStage stage;

  final List<String> seriesExceptions;
  int version;
  int paymentAmountCentavos;
  PaymentTrackingStatus paymentStatus;
  final List<ReservationOccurrence> occurrences;
  final List<ReservationFile> files;

  String get initials => requester
      .replaceAll(RegExp(r'^(Prof\.|Dr\.|Atty\.|Ms\.|Mr\.|Dean|Coach)\s+'), '')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .take(2)
      .map((w) => w[0].toUpperCase())
      .join();

  String get whenLabel => '$date · $start–$end';

  int get startHour => int.tryParse(start.split(':').first) ?? 0;
  int get endHour => int.tryParse(end.split(':').first) ?? 0;

  double get startAt =>
      startHour + (int.tryParse(start.split(':').last) ?? 0) / 60;
  double get endAt => endHour + (int.tryParse(end.split(':').last) ?? 0) / 60;

  bool get isPending => status == RequestStatus.pending;

  bool get overCapacity => heads > capacity;

  int get occurrenceCount {
    final text = recurring;
    if (text == null) return 1;
    final match = RegExp(r'(\d+)\s*occurrence').firstMatch(text);
    return int.tryParse(match?.group(1) ?? '') ?? 1;
  }

  String get cadence => (recurring ?? '').split('·').first.trim();
}

class Booking {
  const Booking({
    required this.id,
    required this.facility,
    required this.date,
    required this.start,
    required this.end,
    required this.label,
    required this.requester,
    this.sourceRequestId,
  });

  final String id;
  final String facility;
  final String date;
  final String start;
  final String end;
  final String label;
  final String requester;

  final String? sourceRequestId;

  double get startAt =>
      (int.tryParse(start.split(':').first) ?? 0) +
      (int.tryParse(start.split(':').last) ?? 0) / 60;

  double get endAt =>
      (int.tryParse(end.split(':').first) ?? 0) +
      (int.tryParse(end.split(':').last) ?? 0) / 60;

  bool overlaps(double from, double to) => startAt < to && from < endAt;
}

const dayStartHour = 7;
const dayEndHour = 20;
