import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/app/app_view.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/profile/profile_screen.dart';
import 'package:smartreserve/theme/sr_theme.dart';

SessionProfile _profile(String role) => SessionProfile(
  id: 'session-id',
  email: 'person@csu.edu.ph',
  fullName: 'CSU Person',
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

BackendNotification _notification({
  required String id,
  required String kind,
  String? requestId,
}) => BackendNotification(
  id: id,
  kind: kind,
  title: 'Title',
  body: 'Body',
  requestId: requestId,
  createdAt: DateTime.utc(2026, 9, 30),
);

void main() {
  group('tapping a device push', () {
    test('routes an admin through the matching in-app notification', () async {
      final state = AppState()
        ..sessionProfile = _profile('internal_admin')
        ..notifications = [
          _notification(id: 'n1', kind: 'feedback_low_rating'),
        ];

      await state.handlePushNotificationOpened(
        'feedback_low_rating',
        null,
        'n1',
      );

      expect(state.view, AppView.feedback);
    });

    test('falls back to the push payload when the row is not loaded', () async {
      final state = AppState()..sessionProfile = _profile('internal_admin');

      await state.handlePushNotificationOpened(
        'reservation_submitted',
        'request-1',
        'missing',
      );

      expect(state.view, AppView.reservations);
    });

    test('focuses the reservation for a renter', () async {
      final state = AppState()..sessionProfile = _profile('user');

      await state.handlePushNotificationOpened(
        'reservation_approved',
        'request-9',
        null,
      );

      expect(state.view, AppView.userApp);
      expect(state.pendingReservationFocusId, 'request-9');
    });

    test('waits for a session before routing', () async {
      final state = AppState();
      final before = state.view;

      await state.handlePushNotificationOpened(
        'reservation_approved',
        'request-9',
        'n1',
      );

      expect(state.view, before);
      expect(state.pendingReservationFocusId, isNull);
    });
  });

  testWidgets('admin profile offers push enrollment', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = AppState()..sessionProfile = _profile('internal_admin');

    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: SrThemeData.light(),
          home: const Scaffold(body: ProfileScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Notifications'), findsOneWidget);
    // No Firebase in tests, so the row reports push as unavailable.
    expect(find.text('Enable push on this device'), findsOneWidget);
  });
}
