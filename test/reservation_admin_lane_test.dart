import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/model/reservation.dart';

SessionProfile _admin(String role) => SessionProfile(
  id: 'admin-session-id',
  email: 'admin@csu.edu.ph',
  fullName: 'CSU Administrator',
  role: role,
  campusClaim: null,
  campusId: null,
  unit: null,
  verificationStatus: 'verified',
  onboardingComplete: true,
  accountStatus: 'active',
  accountAccessType: 'legacy_unassigned',
  mustChangePassword: false,
  createdAt: DateTime.utc(2026),
);

ReservationRequest _request({required String id, required String lane}) =>
    ReservationRequest(
      id: id,
      requesterId: 'u1',
      facility: 'Gymplex',
      building: 'Main campus',
      room: 'Gymplex',
      capacity: 100,
      requester: 'harry',
      role: 'user',
      org: '',
      purpose: 'Event',
      date: '24 September 2026',
      start: '17:30',
      end: '19:00',
      heads: 20,
      submitted: '4 days ago',
      urgent: true,
      attachments: 0,
      noShows: 0,
      status: RequestStatus.pending,
      lifecycleStatus: ReservationLifecycleStatus.pendingApproval,
      adminLane: lane,
    );

void main() {
  group('reservation admin lane', () {
    // The backend gates every decision on admin_lane(caller) = request lane
    // (lock_reservation_admin_scope), while the read policy shows every
    // request to every admin. Acting out of lane returns 42501 'Reservation
    // access denied', so the queue must only offer in-lane rows.
    test('an internal admin may only decide internal-lane requests', () {
      final state = AppState()..sessionProfile = _admin('internal_admin');

      expect(state.currentAdminLane, 'internal');
      expect(
        state.canDecideRequest(_request(id: 'a', lane: 'internal')),
        isTrue,
      );
      expect(
        state.canDecideRequest(_request(id: 'b', lane: 'external')),
        isFalse,
      );
    });

    test('an external admin may only decide external-lane requests', () {
      final state = AppState()..sessionProfile = _admin('external_admin');

      expect(state.currentAdminLane, 'external');
      expect(
        state.canDecideRequest(_request(id: 'a', lane: 'external')),
        isTrue,
      );
      expect(
        state.canDecideRequest(_request(id: 'b', lane: 'internal')),
        isFalse,
      );
    });

    test('the decision queue hides out-of-lane requests', () {
      final state = AppState()
        ..sessionProfile = _admin('internal_admin')
        ..requests = [
          _request(id: 'internal-one', lane: 'internal'),
          _request(id: 'external-one', lane: 'external'),
        ]
        ..requestTab = RequestStatus.pending;

      expect(
        state.visibleRequests.map((r) => r.id),
        ['internal-one'],
        reason: 'the external-lane request would fail the backend lane gate',
      );
    });

    test('selection never lands on an out-of-lane request', () {
      final state = AppState()
        ..sessionProfile = _admin('internal_admin')
        ..requests = [_request(id: 'external-one', lane: 'external')];

      state.setRequestTab(RequestStatus.pending);

      expect(state.visibleRequests, isEmpty);
      expect(state.selectedRequestId, isNull);
    });

    test('demo data without an admin session keeps every request', () {
      final state = AppState()
        ..requests = [
          _request(id: 'internal-one', lane: 'internal'),
          _request(id: 'external-one', lane: 'external'),
        ]
        ..requestTab = RequestStatus.pending;

      expect(state.currentAdminLane, isNull);
      expect(state.visibleRequests, hasLength(2));
    });
  });
}
