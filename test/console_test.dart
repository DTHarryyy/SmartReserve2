import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/data/seed_facilities.dart';
import 'package:smartreserve/data/seed_reservations.dart';
import 'package:smartreserve/features/reports/reports_data.dart';
import 'package:smartreserve/features/reservations/reservation_checks.dart';
import 'package:smartreserve/model/account.dart';
import 'package:smartreserve/model/audit_entry.dart';
import 'package:smartreserve/model/decision_check.dart';
import 'package:smartreserve/model/facility.dart';
import 'package:smartreserve/model/facility_draft.dart';
import 'package:smartreserve/model/facility_photo.dart';
import 'package:smartreserve/model/reservation.dart';
import 'package:smartreserve/model/verification.dart';

FacilityDraft completeDraft() => FacilityDraft()
  ..name = 'Computer Laboratory 2'
  ..category = 'Computer Laboratory'
  ..capacity = '40'
  ..building = 'College of Information and Computing Sciences'
  ..pin = const LatLng(18.35379, 121.63143)
  ..accuracy = 4
  ..photos.add(FacilityPhoto.placeholder(1));

ReservationAssessment assess(AppState state, String requestId) {
  final request = state.requests.firstWhere((r) => r.id == requestId);
  return ReservationAssessment(
    request: request,
    facility: state.facilityNamed(request.facility),
    bookings: state.bookings,
    otherRequests: state.requests,
  );
}

void main() {
  group('reservation checks', () {
    test('an overlapping booking is a hard conflict', () {
      final state = AppState();

      final a = assess(state, 'r1');
      expect(a.hasConflict, isTrue);
      expect(a.conflicts.single.label, contains('IT 3A'));
      expect(
        a.checks.firstWhere((c) => c.label == 'Conflicts').outcome,
        CheckOutcome.fail,
      );
    });

    test('a booking that ends when the request starts does not clash', () {
      final booking = Booking.fromLabels(
        id: 'x',
        facility: 'Computer Laboratory 1',
        date: 'Tue 28 Jul',
        start: '08:00',
        end: '09:00',
        label: 'Earlier class',
        requester: 'Someone',
      );
      expect(booking.overlaps(9, 11), isFalse);
      expect(booking.overlaps(8.5, 11), isTrue);
    });

    test('the next free slot clears every conflict', () {
      final state = AppState();
      final a = assess(state, 'r1');
      final next = a.nextFreeSlot;
      expect(next, isNotNull);

      expect(next!.start, '10:00');
      expect(next.end, '12:00');
    });

    test('headcount over capacity fails the capacity check', () {
      final state = AppState();

      expect(assess(state, 'r4').checks.first.outcome, CheckOutcome.pass);

      expect(assess(state, 'r8').checks.first.outcome, CheckOutcome.fail);
    });

    test('a slot outside operating hours warns rather than blocks', () {
      final state = AppState();

      final a = assess(state, 'r6');
      expect(a.withinOperatingHours, isFalse);
      expect(
        a.checks.firstWhere((c) => c.label == 'Hours & days').outcome,
        CheckOutcome.warn,
      );
    });

    test('a maintenance facility warns', () {
      final state = AppState();
      expect(
        assess(
          state,
          'r4',
        ).checks.firstWhere((c) => c.label == 'Facility state').outcome,
        CheckOutcome.warn,
      );
    });

    test('bulk approve refuses anything carrying a warning', () {
      final state = AppState();
      expect(assess(state, 'r1').bulkApprovable, isFalse, reason: 'conflict');
      expect(assess(state, 'r5').bulkApprovable, isTrue, reason: 'clean');
    });
  });

  group('decisions and the audit trail', () {
    test('approving writes an entry and offers an undo that restores it', () {
      final state = AppState();
      final before = state.audit.length;

      state.decideRequest('r5', RequestStatus.approved);
      expect(
        state.requests.firstWhere((r) => r.id == 'r5').status,
        RequestStatus.approved,
      );
      expect(state.audit.length, before + 1);
      expect(state.audit.first.kind, AuditKind.reservation);
      expect(state.toasts.active?.message.action?.label, 'Undo');

      state.toasts.invokeAction();
      expect(
        state.requests.firstWhere((r) => r.id == 'r5').status,
        RequestStatus.pending,
      );

      expect(state.audit.length, before + 2);
    });

    test(
      'bumping removes the competing booking and books the requester instead',
      () {
        final state = AppState();
        state.bumpFor('r1', 'The competition is the higher priority.');

        expect(
          state.bookings.any((b) => b.label.contains('IT 3A')),
          isFalse,
          reason: 'the bumped booking is gone',
        );
        expect(
          state.bookings.any((b) => b.sourceRequestId == 'r1'),
          isTrue,
          reason: 'the approved request now holds the slot it asked for',
        );
        expect(
          state.requests.firstWhere((r) => r.id == 'r1').status,
          RequestStatus.approved,
        );
        expect(state.audit.first.reason, contains('higher priority'));

        final assessment = assess(state, 'r1');
        expect(assessment.hasConflict, isFalse);
      },
    );

    test(
      'approving in demo mode books exactly one hold; undo and decline release it',
      () {
        final state = AppState();
        expect(state.bookings.any((b) => b.sourceRequestId == 'r6'), isFalse);

        state.decideRequest('r6', RequestStatus.approved);
        expect(
          state.bookings.where((b) => b.sourceRequestId == 'r6').length,
          1,
        );
        expect(assess(state, 'r6').hasConflict, isFalse);

        state.toasts.invokeAction();
        expect(state.bookings.any((b) => b.sourceRequestId == 'r6'), isFalse);
        expect(
          state.requests.firstWhere((r) => r.id == 'r6').status,
          RequestStatus.pending,
        );

        state.decideRequest('r6', RequestStatus.approved, announce: false);
        expect(
          state.bookings.where((b) => b.sourceRequestId == 'r6').length,
          1,
        );

        state.decideRequest('r6', RequestStatus.declined, announce: false);
        expect(state.bookings.any((b) => b.sourceRequestId == 'r6'), isFalse);
      },
    );

    test('a revert appends rather than erasing', () {
      final state = AppState();
      final original = state.audit.first;
      final before = state.audit.length;
      state.revertAudit(original);
      expect(state.audit.length, before + 1);
      expect(state.audit.contains(original), isTrue);
      expect(state.audit.first.diff.first, contains('Reverting'));
    });
  });

  group('verification', () {
    test('the four checks read the submission honestly', () {
      final state = AppState();
      final clean = state.verifications.firstWhere((v) => v.id == 'v1');
      expect(clean.checks.every((c) => c.outcome == CheckOutcome.pass), isTrue);
      expect(clean.bulkApprovable, isTrue);

      final claimed = state.verifications.firstWhere((v) => v.id == 'v3');
      expect(claimed.bulkApprovable, isFalse, reason: 'ID already claimed');

      final illegible = state.verifications.firstWhere((v) => v.id == 'v4');
      expect(illegible.bulkApprovable, isFalse, reason: 'unreadable document');
    });

    test('a name mismatch blocks the summary outright', () {
      final state = AppState();
      final mismatch = state.verifications.firstWhere((v) => v.id == 'v7');
      expect(mismatch.summary.text, contains('does not belong'));
    });

    test('verification changes identity without repricing old requests', () {
      final state = AppState();
      final account = state.accounts.firstWhere((a) => a.id == 'u3');
      expect(account.verification, VerificationState.pending);

      final held = state.requests.firstWhere((r) => r.id == 'r3')
        ..heldForVerification = true
        ..paymentAmountCentavos = 50000
        ..paymentStatus = PaymentTrackingStatus.quoted;

      state.decideVerification('v3', VerificationDecision.approved);

      expect(account.verification, VerificationState.verified);
      expect(held.heldForVerification, isTrue);
      expect(held.paymentAmountCentavos, 50000);
      expect(held.paymentStatus, PaymentTrackingStatus.quoted);
    });

    test('rejection does not transfer an existing reservation lane', () {
      final state = AppState();
      final account = state.accounts.firstWhere((a) => a.id == 'u4');
      final held = state.requests.firstWhere(
        (request) => request.requester == account.name,
      )..heldForVerification = true;
      state.decideVerification(
        'v4',
        VerificationDecision.rejected,
        reason: 'Send a readable photo.',
      );
      expect(account.verification, VerificationState.rejected);
      expect(held.heldForVerification, isTrue);
      expect(held.adminLane, isNotEmpty);
    });
  });

  group('account guardrails', () {
    test('nobody can change their own role', () async {
      final state = AppState();
      final self = state.currentAdmin;
      expect(state.roleChangeBlockedReason(self), contains('their own role'));

      await state.changeRole(self, AccountRole.user);
      expect(self.role, AccountRole.internalAdmin, reason: 'refused');
    });

    test('the last internal admin cannot be demoted', () async {
      final state = AppState();
      final santos = state.accounts.firstWhere((a) => a.id == 'u9');

      expect(state.roleChangeBlockedReason(santos), isNull);

      await state.changeRole(santos, AccountRole.user);
      expect(santos.role, AccountRole.user);

      final registrar = state.currentAdmin;
      expect(state.isLastInternalAdmin(registrar), isTrue);
    });

    test('an invite refuses a duplicate address', () async {
      final state = AppState();
      expect(
        await state.inviteAdmin(
          'm.santos@csu.edu.ph',
          AccountRole.internalAdmin,
          '',
        ),
        contains('already has an account'),
      );
      expect(
        await state.inviteAdmin('not-an-email', AccountRole.internalAdmin, ''),
        contains('valid email'),
      );
      expect(
        await state.inviteAdmin(
          'new.admin@csu.edu.ph',
          AccountRole.internalAdmin,
          '',
        ),
        isNull,
      );
      expect(state.accounts.last.status, AccountStatus.invited);
    });
  });

  group('reports', () {
    test(
      'backend report snapshots preserve metrics and administrator access data',
      () {
        final scope = ReportScope.forRange(
          ReportRange.month,
          now: DateTime(2026, 8, 13, 12),
        );
        final snapshot = ReportSnapshot.fromJson({
          'from': scope.from.toIso8601String(),
          'to': scope.to.toIso8601String(),
          'category': null,
          'generated_at': scope.to.toIso8601String(),
          'summary': {'booked_hours': 8, 'available_hours': 20, 'fraction': .4},
          'utilisation': [
            {
              'facility_id': 'f1',
              'facility_name': 'Room 1',
              'building': 'Main Building',
              'category': 'Classroom',
              'booked_hours': 8,
              'available_hours': 20,
              'fraction': .4,
            },
          ],
          'booked_occurrences': [
            {
              'occurrence_id': 'o1',
              'request_id': 'r1',
              'facility_id': 'f1',
              'requester': 'Student',
              'purpose': 'Class',
              'request_status': 'approved',
              'starts_at': '2026-08-10T01:00:00Z',
              'ends_at': '2026-08-10T09:00:00Z',
              'booked_hours': 8,
            },
          ],
          'demand': [
            for (var day = 1; day <= 7; day++)
              for (var hour = 7; hour <= 19; hour += 2)
                {
                  'day': day,
                  'hour': hour,
                  'count': day == 1 && hour == 7 ? 3 : 0,
                },
          ],
          'performance': {
            'median_hours': 12,
            'within_48': .75,
            'expired': 1,
            'declined': 2,
            'over_capacity': 3,
            'per_admin': [
              {
                'admin_id': 'admin-1',
                'name': 'Registrar',
                'decisions': 4,
                'median_hours': 12,
              },
            ],
          },
        }, expectedScope: scope);
        expect(snapshot.utilisation.single.bookedHours, 8);
        expect(
          snapshot.demand
              .singleWhere((cell) => cell.day == 1 && cell.hour == 7)
              .count,
          3,
        );
        expect(snapshot.performance.perAdmin.single.who, 'Registrar');
      },
    );

    test('utilisation is booked over available, worst first', () {
      final state = AppState();
      final rows = utilisationFor(
        facilities: state.facilities,
        requests: state.requests,
        bookings: state.bookings,
        range: ReportRange.week,
        category: 'All categories',
      );
      expect(rows.length, state.facilities.length);
      for (var i = 1; i < rows.length; i++) {
        expect(rows[i].fraction, greaterThanOrEqualTo(rows[i - 1].fraction));
      }

      expect(rows.first.percent, 0);
    });

    test('the category filter narrows the set', () {
      final state = AppState();
      final rows = utilisationFor(
        facilities: state.facilities,
        requests: state.requests,
        bookings: state.bookings,
        range: ReportRange.week,
        category: 'Auditorium',
      );
      expect(rows, hasLength(1));
      expect(rows.single.facilityName, 'University Auditorium');
    });

    test('relative timestamps parse into hours', () {
      expect(hoursAgo('3 days ago'), 72);
      expect(hoursAgo('6 hours ago'), 6);
      expect(hoursAgo('Yesterday 16:20'), 24);
      expect(hoursAgo('Just now'), 0);
      expect(hoursAgo(null), isNull);
      expect(hoursAgo('sometime'), isNull);
    });

    test('median time-to-decision ignores unparseable rows', () {
      final performance = performanceFor(seedRequests());
      expect(performance.medianHours, isNotNull);
      expect(performance.perAdmin, isNotEmpty);
      expect(performance.perAdmin.first.who, 'You');
    });

    test('data quality flags the unpinned room and nothing clean', () {
      final facilities = seedFacilities();
      final issues = qualityIssuesFor(facilities);
      expect(issues, hasLength(1));
      expect(issues.single.facility.name, 'Faculty Conference Room');
      expect(issues.single.severity, QualitySeverity.blocking);
    });

    test('a pin outside the boundary is blocking', () {
      final facilities = seedFacilities();
      facilities.first.coords = const LatLng(18.40, 121.70);
      final issues = qualityIssuesFor(facilities);
      expect(
        issues.any(
          (i) =>
              i.facility.name == 'Computer Laboratory 1' &&
              i.severity == QualitySeverity.blocking,
        ),
        isTrue,
      );
    });

    test('a pin far from its building is a warning, not a block', () {
      final facilities = seedFacilities();

      facilities.first.coords = const LatLng(18.352232, 121.647860);
      final issue = qualityIssuesFor(
        facilities,
      ).firstWhere((i) => i.facility.name == 'Computer Laboratory 1');
      expect(issue.severity, QualitySeverity.warning);
      expect(issue.issue, contains('further than'));
    });

    test('the demand heatmap counts requests into two-hour blocks', () {
      final heatmap = demandFor(seedRequests());
      expect(heatmap.days, hasLength(7));
      expect(heatmap.peak, greaterThan(0));

      expect(heatmap.cells[5].every((n) => n == 0), isTrue);
      expect(heatmap.cells[6].every((n) => n == 0), isTrue);
    });
  });

  group('student bookings', () {
    test('a member request goes straight into the queue', () {
      final state = AppState();
      final before = state.requests.length;
      final facility = state.facilityNamed('Reading Hall B')!;

      state.submitBooking(
        facility: facility,
        date: 'Thu 30 Jul',
        start: '09:00',
        end: '11:00',
        heads: 20,
        purpose: 'Study group',
      );

      expect(state.requests.length, before + 1);
      expect(state.requests.first.heldForVerification, isFalse);
      expect(state.requests.first.status, RequestStatus.pending);
    });

    test('a pending member request enters the external lane', () {
      final state = AppState()..signInAsUser('u3');
      final facility = state.facilityNamed('Reading Hall B')!;

      state.submitBooking(
        facility: facility,
        date: 'Thu 30 Jul',
        start: '09:00',
        end: '11:00',
        heads: 20,
        purpose: 'Peer tutoring',
      );

      expect(state.requests.first.heldForVerification, isFalse);
      expect(state.requests.first.adminLane, 'external');
    });

    test('verification derives pricing audience without authorizing price', () {
      final state = AppState();
      final auditorium = state.facilityNamed('University Auditorium')!;
      expect(state.quoteFor(auditorium, 2), greaterThan(0));
      expect(state.userAccount.pricingAudience, isNot('guest'));

      state.signInAsUser('u5');
      expect(state.userAccount.pricingAudience, 'guest');
    });
  });

  group('saving a facility', () {
    test('creating from a draft logs it and moves the mapped count', () {
      final state = AppState();
      final mapped = state.mappedCount;
      final total = state.catalogueTotal;

      final draft = completeDraft();
      final saved = state.saveFromDraft(draft);

      expect(saved.name, 'Computer Laboratory 2');
      expect(state.facilities.first.id, saved.id);
      expect(state.mappedCount, mapped + 1);
      expect(state.catalogueTotal, total + 1);
      expect(state.audit.first.action, contains('created'));
    });

    test('a knowingly out-of-boundary pin saves as under review', () {
      final state = AppState();
      final draft = completeDraft()
        ..pin = const LatLng(18.40, 121.70)
        ..confirmedOutside = true;

      final saved = state.saveFromDraft(draft);
      expect(saved.state, FacilityState.underReview);
      expect(saved.pinConfidence, PinConfidence.needsCheck);
      expect(state.audit.first.reason, contains('flagged for review'));
    });

    test('archiving offers an undo that puts the record back', () {
      final state = AppState();
      final facility = state.facilities.first;
      final count = state.facilities.length;

      state.deleteFacility(facility);
      expect(state.facilities.length, count - 1);

      state.toasts.invokeAction();
      expect(state.facilities.length, count);
      expect(state.facilities.first.id, facility.id);
    });
  });
}
