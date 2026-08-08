import '../../model/reservation.dart';
import '../../util/campus_calendar.dart';

class SeriesOccurrence {
  const SeriesOccurrence({
    required this.date,
    required this.label,
    required this.clash,
    required this.excepted,
  });

  final DateTime date;

  final String label;

  final String? clash;

  final bool excepted;

  bool get free => clash == null;

  String get note {
    if (excepted) return '$label — returned to the requester for a new time.';
    return clash == null ? '$label — the room is free.' : '$label — $clash';
  }
}

class ReservationSeries {
  ReservationSeries({
    required this.request,
    required this.bookings,
    required this.otherRequests,
  });

  final ReservationRequest request;
  final List<Booking> bookings;
  final List<ReservationRequest> otherRequests;

  bool get applies => request.recurring != null && start != null;

  DateTime? get start => parseCampusDate(request.date);

  List<SeriesOccurrence> get occurrences {
    final from = start;
    if (from == null) return const [];
    return [
      for (var i = 0; i < request.occurrenceCount; i++)
        _occurrence(from.add(Duration(days: 7 * i))),
    ];
  }

  SeriesOccurrence _occurrence(DateTime date) {
    final label = formatCampusDate(date);
    return SeriesOccurrence(
      date: date,
      label: label,
      clash: _clashOn(label),
      excepted: request.seriesExceptions.contains(label),
    );
  }

  String? _clashOn(String date) {
    for (final b in bookings) {
      if (b.facility != request.facility ||
          b.date != date ||
          b.sourceRequestId == request.id) {
        continue;
      }
      if (b.overlaps(request.startAt, request.endAt)) {
        return '${b.label} holds ${b.start}–${b.end}.';
      }
    }
    for (final r in otherRequests) {
      if (r.id == request.id ||
          r.status != RequestStatus.approved ||
          r.facility != request.facility ||
          r.date != date) {
        continue;
      }
      if (r.startAt < request.endAt && request.startAt < r.endAt) {
        return '${r.requester} is approved for ${r.start}–${r.end}.';
      }
    }
    return null;
  }

  List<SeriesOccurrence> get free => [
    for (final o in occurrences)
      if (o.free) o,
  ];

  List<SeriesOccurrence> get clashing => [
    for (final o in occurrences)
      if (!o.free) o,
  ];

  String get summary {
    final all = occurrences;
    if (all.isEmpty) return request.recurring ?? '';
    final clashes = clashing.length;
    return '${request.occurrenceCount} dates from ${all.first.label} to '
        '${all.last.label} · '
        '${clashes == 0 ? 'all free' : '$clashes clash${clashes == 1 ? '' : 'es'}'}';
  }
}
