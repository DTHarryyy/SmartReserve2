import '../../model/reservation.dart';
import '../../util/campus_calendar.dart';

const kCollidesFlag = 'Collides with a booking';
const kOverlapsFlag = 'Overlaps another booking';
const kCollidesTitle = 'Collides with an existing booking';

class Hold {
  const Hold({
    required this.label,
    required this.requester,
    required this.startsAt,
    required this.endsAt,
    this.sourceRequestId,
  });

  final String label;
  final String requester;
  final DateTime startsAt;
  final DateTime endsAt;

  final String? sourceRequestId;

  double get startAt => startsAt.hour + startsAt.minute / 60;
  double get endAt => endsAt.hour + endsAt.minute / 60;

  String get start => formatClock12(startAt);
  String get end => formatClock12(endAt);

  String get note => '$label holds $start–$end.';
}

List<Hold> holdsAgainst({
  required ReservationRequest request,
  required List<Booking> bookings,
  required List<ReservationRequest> otherRequests,
  DateTime? onDay,
  bool overlappingOnly = true,
}) {
  final rawDay = onDay ?? request.slotDay;
  if (rawDay == null) return const [];
  final day = dayOnly(rawDay);

  final from = atClock(day, request.start);
  final to = atClock(day, request.end);
  if (from == null || to == null) return const [];

  final holds = <Hold>[];

  final covered = <String>{};

  for (final booking in bookings) {
    if (booking.sourceRequestId == request.id) continue;
    if (!_sameFacility(
      booking.facilityId,
      booking.facility,
      request.facilityId,
      request.facility,
    )) {
      continue;
    }
    if (booking.day != day) continue;

    final sourceId = booking.sourceRequestId;
    if (sourceId != null) covered.add(sourceId);

    if (overlappingOnly && !booking.overlapsRange(from, to)) continue;
    holds.add(
      Hold(
        label: booking.label,
        requester: booking.requester,
        startsAt: booking.startsAt,
        endsAt: booking.endsAt,
        sourceRequestId: sourceId,
      ),
    );
  }

  for (final other in otherRequests) {
    if (other.id == request.id) continue;
    if (covered.contains(other.id)) continue;
    if (other.status != RequestStatus.approved) continue;
    if (!_sameFacility(
      other.facilityId,
      other.facility,
      request.facilityId,
      request.facility,
    )) {
      continue;
    }

    final otherStart = atClock(other.slotDay, other.start);
    final otherEnd = atClock(other.slotDay, other.end);
    if (otherStart == null || otherEnd == null) continue;
    if (dayOnly(otherStart) != day) continue;
    if (overlappingOnly &&
        !(otherStart.isBefore(to) && from.isBefore(otherEnd))) {
      continue;
    }

    holds.add(
      Hold(
        label: other.purpose,
        requester: other.requester,
        startsAt: otherStart,
        endsAt: otherEnd,
        sourceRequestId: other.id,
      ),
    );
  }

  holds.sort((a, b) => a.startsAt.compareTo(b.startsAt));
  return holds;
}

bool _sameFacility(
  String? leftId,
  String leftName,
  String? rightId,
  String rightName,
) {
  if (leftId != null && rightId != null) return leftId == rightId;
  return leftName.trim() == rightName.trim();
}
