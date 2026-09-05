import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';
import '../util/campus_calendar.dart';
import 'payment.dart';
import 'permit.dart';

enum BookingStage {
  booked('Approved', 'Approved — the room is held and the requester notified.'),
  checkedIn('Checked in', 'Checked in — attendees are in the room.'),
  completed('Completed', 'Completed and closed.'),
  noShow(
    'No-show',
    'The requester did not check in before the grace period ended.',
  );

  const BookingStage(this.label, this.summary);

  final String label;
  final String summary;

  bool operator >=(BookingStage other) => index >= other.index;
}

enum RequestStatus {
  pending('pending', 'Needs decision', SrTone.warning),
  approved('approved', 'Approved', SrTone.success),
  declined('declined', 'Declined', SrTone.error),
  changesRequested('changes', 'Changes requested', SrTone.info),
  cancelled('cancelled', 'Cancelled', SrTone.neutral),
  expired('expired', 'Expired', SrTone.neutral);

  const RequestStatus(this.raw, this.label, this.tone);

  final String raw;
  final String label;
  final SrTone tone;

  Color get background => tone.tint;
  Color get foreground => tone.ink;

  static RequestStatus fromRaw(String raw) => values.firstWhere(
    (s) =>
        s.raw == raw ||
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

enum ReservationLifecycleStatus {
  pendingApproval('pending_approval', 'Pending approval'),
  changesRequested('changes_requested', 'Changes requested'),
  awaitingPayment('awaiting_payment', 'Awaiting payment'),
  confirmed('confirmed', 'Confirmed'),
  declined('declined', 'Declined'),
  cancelled('cancelled', 'Cancelled'),
  expired('expired', 'Expired'),
  completed('completed', 'Completed');

  const ReservationLifecycleStatus(this.raw, this.label);
  final String raw;
  final String label;

  SrTone get tone => switch (this) {
    ReservationLifecycleStatus.pendingApproval ||
    ReservationLifecycleStatus.awaitingPayment => SrTone.warning,
    ReservationLifecycleStatus.changesRequested => SrTone.info,
    ReservationLifecycleStatus.confirmed ||
    ReservationLifecycleStatus.completed => SrTone.success,
    ReservationLifecycleStatus.declined => SrTone.error,
    ReservationLifecycleStatus.cancelled ||
    ReservationLifecycleStatus.expired => SrTone.neutral,
  };

  Color get background => tone.tint;
  Color get foreground => tone.ink;

  static ReservationLifecycleStatus fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => ReservationLifecycleStatus.pendingApproval,
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
    this.attendanceMarkedAt,
    this.attendanceMarkedBy,
    this.attendanceReason,
    this.cancelledAt,
    this.cancelledBy,
    this.cancellationReason,
  });

  final String id;
  final DateTime startsAt;
  final DateTime endsAt;
  final String bookingState;
  final BookingStage stage;
  final DateTime? proposedStartsAt;
  final DateTime? proposedEndsAt;
  final String? reason;
  final DateTime? attendanceMarkedAt;
  final String? attendanceMarkedBy;
  final String? attendanceReason;
  final DateTime? cancelledAt;
  final String? cancelledBy;
  final String? cancellationReason;

  bool get isBooked => bookingState == 'booked';
  bool get needsNewTime =>
      bookingState == 'changes_requested' || bookingState == 'bumped';
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
    DateTime? slotDay,
    List<ReservationOccurrence>? occurrences,
    List<ReservationFile>? files,
    List<String>? amenities,
    this.adminLane = 'external',
    this.lifecycleStatus = ReservationLifecycleStatus.pendingApproval,
    this.pricingAudience = 'guest',
    this.facilityAmountCentavos = 0,
    this.amenityAmountCentavos = 0,
    this.discountAmountCentavos = 0,
    this.totalAmountCentavos = 0,
    this.requiredDownPaymentCentavos = 0,
    this.downPaymentPercent = 50,
    this.paymentExemption = 'none',
    this.paymentDueAt,
    this.balanceDueAt,
    this.legacyFinancialState = false,
    List<PaymentTransaction>? paymentTransactions,
    this.paymentMethod,
    List<PriceSnapshotLine>? priceLines,
    List<AcceptedTerms>? acceptedTerms,
    this.feedbackRating,
    this.feedbackComment = '',
    this.feedbackAt,
    this.permit,
  }) : seriesExceptions = seriesExceptions ?? <String>[],
       slotDay = slotDay ?? parseCampusDate(date),
       occurrences = occurrences ?? <ReservationOccurrence>[],
       files = files ?? <ReservationFile>[],
       amenities = amenities ?? <String>[],
       paymentTransactions = paymentTransactions ?? <PaymentTransaction>[],
       priceLines = priceLines ?? <PriceSnapshotLine>[],
       acceptedTerms = acceptedTerms ?? <AcceptedTerms>[];

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

  final DateTime? slotDay;

  String start;
  String end;
  final int heads;

  final String submitted;
  final bool urgent;
  final int attachments;

  final String? recurring;

  int noShows;

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
  final List<String> amenities;
  final String adminLane;
  ReservationLifecycleStatus lifecycleStatus;
  final String pricingAudience;
  final int facilityAmountCentavos;
  final int amenityAmountCentavos;
  final int discountAmountCentavos;
  final int totalAmountCentavos;
  final int requiredDownPaymentCentavos;
  final int downPaymentPercent;
  final String paymentExemption;
  final DateTime? paymentDueAt;
  final DateTime? balanceDueAt;
  final bool legacyFinancialState;
  final List<PaymentTransaction> paymentTransactions;
  final FacilityPaymentMethod? paymentMethod;
  final List<PriceSnapshotLine> priceLines;
  final List<AcceptedTerms> acceptedTerms;
  final ReservationPermit? permit;

  bool get isPaymentExempt => paymentExemption != 'none';

  /// Null until the requester leaves feedback -- arrives with the
  /// reservation fetch via the reservation_feedback embed, so no separate
  /// lookup is needed. Mutated in place by AppState.submitFeedback for an
  /// immediate UI update.
  int? feedbackRating;
  String feedbackComment;
  DateTime? feedbackAt;

  int get verifiedAmountCentavos => paymentTransactions
      .where((payment) => payment.status == PaymentDecisionStatus.verified)
      .fold(0, (total, payment) => total + payment.amountCentavos);

  int get outstandingAmountCentavos {
    final value = totalAmountCentavos - verifiedAmountCentavos;
    if (value < 0) return 0;
    return value > totalAmountCentavos ? totalAmountCentavos : value;
  }

  AggregatePaymentStatus get aggregatePaymentStatus {
    if (totalAmountCentavos == 0) return AggregatePaymentStatus.notRequired;
    if (verifiedAmountCentavos >= totalAmountCentavos) {
      return AggregatePaymentStatus.fullyPaid;
    }
    if (balanceDueAt != null && balanceDueAt!.isBefore(DateTime.now())) {
      return AggregatePaymentStatus.overdue;
    }
    if (verifiedAmountCentavos >= requiredDownPaymentCentavos) {
      return AggregatePaymentStatus.downPaymentVerified;
    }
    if (paymentTransactions.any(
      (payment) => payment.status == PaymentDecisionStatus.submitted,
    )) {
      return AggregatePaymentStatus.submitted;
    }
    if (verifiedAmountCentavos > 0) {
      return AggregatePaymentStatus.partiallyPaid;
    }
    return AggregatePaymentStatus.unpaid;
  }

  /// Mirrors the server's issue_reservation_permit gate: confirmed, and
  /// either exempt or fully paid. The server re-checks this independently --
  /// this getter only decides what the UI offers, never what is allowed.
  bool get permitEligible =>
      lifecycleStatus == ReservationLifecycleStatus.confirmed &&
      (totalAmountCentavos == 0 ||
          verifiedAmountCentavos >= totalAmountCentavos);

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

  DateTime? get startsAtWall => atClock(slotDay, start);
  DateTime? get endsAtWall => atClock(slotDay, end);

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
    required this.startsAt,
    required this.endsAt,
    required this.label,
    required this.requester,
    this.facilityId,
    this.sourceRequestId,
  });

  factory Booking.fromLabels({
    required String id,
    required String facility,
    required String date,
    required String start,
    required String end,
    required String label,
    required String requester,
    String? facilityId,
    String? sourceRequestId,
  }) {
    final day = parseCampusDate(date) ?? campusToday;
    return Booking(
      id: id,
      facility: facility,
      startsAt: atClock(day, start)!,
      endsAt: atClock(day, end)!,
      label: label,
      requester: requester,
      facilityId: facilityId,
      sourceRequestId: sourceRequestId,
    );
  }

  final String id;

  final String facility;

  final String? facilityId;

  final DateTime startsAt;
  final DateTime endsAt;
  final String label;
  final String requester;

  final String? sourceRequestId;

  String get date => formatCampusDate(startsAt);
  String get start => formatClock(startAt);
  String get end => formatClock(endAt);

  DateTime get day => dayOnly(startsAt);

  double get startAt => startsAt.hour + startsAt.minute / 60;

  double get endAt => endsAt.hour + endsAt.minute / 60;

  bool overlaps(double from, double to) => startAt < to && from < endAt;

  bool overlapsRange(DateTime from, DateTime to) =>
      startsAt.isBefore(to) && from.isBefore(endsAt);
}

const dayStartHour = 7;
const dayEndHour = 20;
