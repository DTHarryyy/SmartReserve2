import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/facility_draft.dart';
import 'package:smartreserve/model/payment.dart';
import 'package:smartreserve/model/reservation.dart';

DateTime _at(int hour, [int minute = 0]) =>
    DateTime.utc(2026, 10, 5, hour, minute);

int _billable({
  required bool campus,
  required DateTime oldEnd,
  required DateTime newEnd,
  int grace = 0,
}) => extraTimeBillableMinutes(
  campus: campus,
  oldEnd: oldEnd,
  newEnd: newEnd,
  graceMinutes: grace,
);

ReservationRequest _request({
  String lane = 'internal',
  int total = 0,
  List<ReservationTimeCharge> charges = const [],
  List<PaymentTransaction> payments = const [],
  ReservationLifecycleStatus status = ReservationLifecycleStatus.confirmed,
}) => ReservationRequest(
  id: 'r1',
  facility: 'Hall',
  building: 'B',
  room: '',
  capacity: 50,
  requester: 'Campus Rep',
  role: 'user',
  org: 'College',
  purpose: 'Rehearsal',
  date: 'Oct 5',
  start: '16:00',
  end: '17:00',
  heads: 10,
  submitted: 'now',
  urgent: false,
  attachments: 0,
  noShows: 0,
  status: RequestStatus.approved,
  adminLane: lane,
  lifecycleStatus: status,
  totalAmountCentavos: total,
  requiredDownPaymentCentavos: (total * 50 + 99) ~/ 100,
  timeCharges: List.of(charges),
  paymentTransactions: List.of(payments),
);

ReservationTimeCharge _charge({
  int amount = 20000,
  TimeChargeStatus status = TimeChargeStatus.approved,
  TimeChargeKind kind = TimeChargeKind.overtime,
}) => ReservationTimeCharge(
  id: 'c-$amount-${status.raw}',
  occurrenceId: 'o1',
  kind: kind,
  status: status,
  createdAt: _at(18),
  billableMinutes: amount == 0 ? 0 : 60,
  hourlyRateCentavos: 20000,
  amountCentavos: amount,
);

PaymentTransaction _verified(int amount) => PaymentTransaction(
  id: 'p-$amount',
  requestId: 'r1',
  payerId: 'u1',
  purpose: PaymentPurpose.adjustment,
  amountCentavos: amount,
  referenceNumber: 'OR-1',
  proofPath: 'u1/r1/p.jpg',
  status: PaymentDecisionStatus.verified,
  submittedAt: _at(19),
);

void main() {
  group('afterHoursMinutes', () {
    test('only counts time after 5:00 PM', () {
      expect(afterHoursMinutes(_at(15), _at(17, 30)), 30);
      expect(afterHoursMinutes(_at(13), _at(16)), 0);
      expect(afterHoursMinutes(_at(18), _at(19)), 60);
    });
  });

  group('extraTimeBillableMinutes (mirrors the SQL tests)', () {
    test('campus extension before 5 PM is free', () {
      expect(_billable(campus: true, oldEnd: _at(15), newEnd: _at(16)), 0);
    });

    test('campus extension from 5 to 6 PM bills one hour', () {
      expect(_billable(campus: true, oldEnd: _at(17), newEnd: _at(18)), 60);
    });

    test('campus overtime within the grace is free', () {
      expect(
        _billable(campus: true, oldEnd: _at(17), newEnd: _at(17, 10), grace: 15),
        0,
      );
    });

    test('campus overtime 20 min past 5 PM bills one hour', () {
      expect(
        _billable(campus: true, oldEnd: _at(17), newEnd: _at(17, 20), grace: 15),
        60,
      );
    });

    test('campus overtime before 5 PM is free', () {
      expect(
        _billable(campus: true, oldEnd: _at(15), newEnd: _at(15, 40), grace: 15),
        0,
      );
    });

    test('campus overtime 90 min past 5 PM bills two hours', () {
      expect(
        _billable(campus: true, oldEnd: _at(17), newEnd: _at(18, 30), grace: 15),
        120,
      );
    });

    test('renter overtime of 16 minutes bills one hour at any time', () {
      expect(
        _billable(campus: false, oldEnd: _at(11), newEnd: _at(11, 16), grace: 15),
        60,
      );
    });

    test('renter extension is billed at any hour', () {
      expect(_billable(campus: false, oldEnd: _at(10), newEnd: _at(11)), 60);
    });

    test('amount is whole hours times the rate', () {
      expect(
        extraTimeAmountCentavos(billableMinutes: 120, hourlyRateCentavos: 20000),
        40000,
      );
    });
  });

  group('ReservationRequest payable total', () {
    test('a free campus booking owes its approved overtime', () {
      final request = _request(charges: [_charge()]);
      expect(request.payableTotalCentavos, 20000);
      expect(request.outstandingAmountCentavos, 20000);
      expect(request.aggregatePaymentStatus, AggregatePaymentStatus.unpaid);
    });

    test('pending, declined and waived charges are not owed', () {
      final request = _request(
        charges: [
          _charge(status: TimeChargeStatus.requested, kind: TimeChargeKind.extension),
          _charge(amount: 40000, status: TimeChargeStatus.waived),
        ],
      );
      expect(request.payableTotalCentavos, 0);
      expect(request.aggregatePaymentStatus, AggregatePaymentStatus.notRequired);
      expect(request.hasPendingExtension, isTrue);
      expect(request.pendingExtensionFor('o1'), isNotNull);
    });

    test('paying the overtime settles the reservation', () {
      final request = _request(
        charges: [_charge()],
        payments: [_verified(20000)],
        status: ReservationLifecycleStatus.completed,
      );
      expect(request.outstandingAmountCentavos, 0);
      expect(request.aggregatePaymentStatus, AggregatePaymentStatus.fullyPaid);
    });

    test('a paid base with unpaid overtime is partially paid', () {
      final request = _request(
        lane: 'external',
        total: 50000,
        charges: [_charge()],
        payments: [_verified(50000)],
      );
      expect(request.outstandingAmountCentavos, 20000);
      expect(
        request.aggregatePaymentStatus,
        AggregatePaymentStatus.partiallyPaid,
      );
    });
  });

  group('occurrence checkout and extension eligibility', () {
    final occurrence = ReservationOccurrence(
      id: 'o1',
      startsAt: _at(15),
      endsAt: _at(17),
      bookingState: 'booked',
      stage: BookingStage.checkedIn,
    );

    test('checkout is available the whole time a group is checked in', () {
      expect(occurrence.canCheckOut, isTrue);
    });

    test('extensions can be requested only before the end', () {
      expect(occurrence.canRequestExtensionAt(_at(16, 59)), isTrue);
      expect(occurrence.canRequestExtensionAt(_at(17)), isFalse);
    });

    test('overtime minutes round up like the server', () {
      expect(occurrence.overtimeMinutesAt(_at(17, 20)), 20);
      expect(occurrence.overtimeMinutesAt(_at(16)), 0);
    });
  });

  group('FacilityDraft overtime rate', () {
    test('is required and must be above zero', () {
      final draft = FacilityDraft();
      expect(draft.validate().containsKey(RequiredItem.overtimeRate), isTrue);
      draft.overtimeRate = '0';
      expect(draft.validate().containsKey(RequiredItem.overtimeRate), isTrue);
      draft.overtimeRate = '200';
      expect(draft.validate().containsKey(RequiredItem.overtimeRate), isFalse);
      expect(draft.overtimeRateCentavos, 20000);
      expect(draft.has(RequiredItem.overtimeRate), isTrue);
    });

    test('survives the autosave round trip', () {
      final draft = FacilityDraft()..overtimeRate = '150.50';
      final restored = FacilityDraft.fromJson(draft.toJson());
      expect(restored.overtimeRate, '150.50');
      expect(restored.overtimeRateCentavos, 15050);
      expect(FacilityDraft.pesosText(15050), '150.50');
      expect(FacilityDraft.pesosText(20000), '200');
    });
  });
}
