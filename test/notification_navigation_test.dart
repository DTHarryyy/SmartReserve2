import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/model/notification_navigation.dart';

void main() {
  group('notification navigation', () {
    test('known admin reservation families select the right section', () {
      final cases = <String, NotificationFocus>{
        'reservation_submitted': NotificationFocus.review,
        'reservation_resubmitted': NotificationFocus.review,
        'reservation_released': NotificationFocus.review,
        'reservation_reschedule_requested': NotificationFocus.review,
        'payment_submitted': NotificationFocus.payment,
        'payment_corrected': NotificationFocus.payment,
        'reservation_extension_requested': NotificationFocus.extraTime,
        'reservation_checked_out': NotificationFocus.extraTime,
      };

      for (final entry in cases.entries) {
        final intent = resolveNotificationNavigation(
          kind: entry.key,
          isAdmin: true,
          requestId: 'r1',
        );
        expect(
          intent.destination,
          NotificationDestination.adminReservation,
          reason: entry.key,
        );
        expect(intent.focus, entry.value, reason: entry.key);
      }
    });

    test('known renter families select details or eligible forms', () {
      final cases =
          <(String, NotificationFocus, NotificationDestination, bool)>[
            (
              'signature_requested',
              NotificationFocus.signature,
              NotificationDestination.renterReservation,
              true,
            ),
            (
              'payment_needs_correction',
              NotificationFocus.payment,
              NotificationDestination.renterReservation,
              true,
            ),
            (
              'reservation_payment_instructions',
              NotificationFocus.payment,
              NotificationDestination.renterReservation,
              true,
            ),
            (
              'payment_reminder',
              NotificationFocus.payment,
              NotificationDestination.renterReservation,
              true,
            ),
            (
              'reservation_overtime_due',
              NotificationFocus.payment,
              NotificationDestination.renterReservation,
              true,
            ),
            (
              'permit_available',
              NotificationFocus.permit,
              NotificationDestination.renterReservation,
              true,
            ),
            (
              'reservation_bumped',
              NotificationFocus.actions,
              NotificationDestination.renterReservation,
              false,
            ),
            (
              'facility_maintenance',
              NotificationFocus.actions,
              NotificationDestination.renterReservation,
              false,
            ),
            (
              'reservation_reminder',
              NotificationFocus.attendance,
              NotificationDestination.renterReservation,
              false,
            ),
            (
              'reservation_self_check_in',
              NotificationFocus.attendance,
              NotificationDestination.renterReservation,
              false,
            ),
            (
              'feedback_reply',
              NotificationFocus.feedback,
              NotificationDestination.renterReservation,
              false,
            ),
            (
              'reservation_use_assessment',
              NotificationFocus.feedback,
              NotificationDestination.renterReservation,
              false,
            ),
            (
              'loyalty_earned',
              NotificationFocus.details,
              NotificationDestination.loyalty,
              false,
            ),
          ];

      for (final entry in cases) {
        final intent = resolveNotificationNavigation(
          kind: entry.$1,
          isAdmin: false,
          requestId: 'r1',
        );
        expect(intent.focus, entry.$2, reason: entry.$1);
        expect(intent.destination, entry.$3, reason: entry.$1);
        expect(intent.openForm, entry.$4, reason: entry.$1);
      }
    });

    test('role restrictions never open renter forms for administrators', () {
      for (final kind in ['signature_requested', 'payment_needs_correction']) {
        final intent = resolveNotificationNavigation(
          kind: kind,
          isAdmin: true,
          requestId: 'r1',
        );
        expect(intent.destination, NotificationDestination.adminReservation);
        expect(intent.openForm, isFalse);
      }
    });

    test('admin payment targets the exact payment review', () {
      final intent = resolveNotificationNavigation(
        kind: 'payment_submitted',
        isAdmin: true,
        requestId: 'r1',
        eventDetails: const {'payment_id': 'p1'},
      );

      expect(intent.destination, NotificationDestination.adminReservation);
      expect(intent.focus, NotificationFocus.payment);
      expect(intent.resourceId, 'p1');
      expect(intent.actionLabel, 'Review payment');
    });

    test('payment correction opens the renter correction form', () {
      final intent = resolveNotificationNavigation(
        kind: 'payment_needs_correction',
        isAdmin: false,
        requestId: 'r1',
        eventDetails: const {'payment_id': 'p1'},
      );

      expect(intent.destination, NotificationDestination.renterReservation);
      expect(intent.focus, NotificationFocus.payment);
      expect(intent.resourceId, 'p1');
      expect(intent.openForm, isTrue);
      expect(intent.actionLabel, 'Fix payment');
    });

    test('signature requests open the signing flow', () {
      final intent = resolveNotificationNavigation(
        kind: 'signature_requested',
        isAdmin: false,
        requestId: 'r1',
      );

      expect(intent.focus, NotificationFocus.signature);
      expect(intent.openForm, isTrue);
      expect(intent.actionLabel, 'Sign now');
    });

    test('facility announcements retain an exact facility target', () {
      final intent = resolveNotificationNavigation(
        kind: 'new_facility',
        isAdmin: false,
        eventDetails: const {'facility_id': 'f1'},
      );

      expect(intent.destination, NotificationDestination.browse);
      expect(intent.resourceId, 'f1');
    });

    test('legacy changed notices focus the renter action area', () {
      final intent = resolveNotificationNavigation(
        kind: 'reservation_changed',
        isAdmin: false,
        requestId: 'r1',
      );

      expect(intent.destination, NotificationDestination.renterReservation);
      expect(intent.focus, NotificationFocus.actions);
      expect(intent.openForm, isFalse);
    });

    test('anomaly alerts select anomaly details', () {
      final intent = resolveNotificationNavigation(
        kind: 'anomaly_critical',
        isAdmin: true,
        anomalyId: 'a1',
      );

      expect(intent.destination, NotificationDestination.anomalies);
      expect(intent.anomalyId, 'a1');
      expect(intent.actionLabel, 'Review alert');
    });

    test('unknown request kinds safely open request details', () {
      final intent = resolveNotificationNavigation(
        kind: 'legacy_reservation_notice',
        isAdmin: false,
        requestId: 'r1',
      );

      expect(intent.destination, NotificationDestination.renterReservation);
      expect(intent.focus, NotificationFocus.details);
      expect(intent.openForm, isFalse);
    });

    test('unlinked unknown kinds are unavailable', () {
      final intent = resolveNotificationNavigation(
        kind: 'legacy_notice',
        isAdmin: false,
      );

      expect(intent.destination, NotificationDestination.unavailable);
    });
  });

  test('notification parsing retains event ids and joined details', () {
    final notification = BackendNotification.fromJson({
      'id': 'n1',
      'kind': 'payment_submitted',
      'title': 'Payment submitted',
      'body': 'Review it',
      'event_id': 'e1',
      'created_at': '2026-10-01T10:00:00Z',
      'event': {
        'details': {'payment_id': 'p1'},
      },
    });

    expect(notification.eventId, 'e1');
    expect(notification.eventDetails, {'payment_id': 'p1'});
    expect(notification.unread, isTrue);
  });
}
