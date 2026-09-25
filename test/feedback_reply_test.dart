import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/student/student_app.dart';
import 'package:smartreserve/model/feedback.dart';
import 'package:smartreserve/model/reservation.dart';
import 'package:smartreserve/theme/sr_theme.dart';

Future<void> _pumpMyReservations(
  WidgetTester tester,
  AppState state, {
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    AppScope(
      state: state,
      child: MaterialApp(
        theme: SrThemeData.light(),
        debugShowCheckedModeBanner: false,
        builder: (context, child) =>
            SrThemeBridge(child: child ?? const SizedBox.shrink()),
        home: const Scaffold(body: StudentApp()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // The bottom nav shows StudentTab.short ('Reservation'); the longer
  // 'My reservations' label is semantics-only (see _BottomNavItem).
  await tester.tap(find.text('Reservation').last);
  await tester.pumpAndSettle();
}

ReservationRequest _reviewedRequest({FeedbackReply? reply}) => ReservationRequest(
  id: 'far-r1',
  facility: 'Computer Laboratory 1',
  building: 'College of Information and Computing Sciences',
  room: 'CICS-201',
  capacity: 40,
  requester: 'Jomar Padilla',
  role: 'User · BSIT 4A',
  org: 'Junior Philippine Computer Society',
  purpose: 'A completed booking with a review already on file.',
  date: 'Tue 28 Jul',
  start: '09:00',
  end: '11:00',
  heads: 32,
  submitted: '3 days ago',
  urgent: false,
  attachments: 0,
  noShows: 0,
  status: RequestStatus.approved,
  lifecycleStatus: ReservationLifecycleStatus.completed,
  feedbackRating: 5,
  feedbackComment: 'Great room, thank you.',
  feedbackReply: reply,
);

void main() {
  group('BackendFeedbackReply', () {
    test('parses from the embedded reservation_feedback_replies shape', () {
      final feedback = BackendFeedback.fromJson({
        'id': 'feedback-1',
        'reservation_id': 'res-1',
        'facility_id': 'fac-1',
        'user_id': 'user-1',
        'rating': 5,
        'created_at': '2026-09-01T00:00:00Z',
        'updated_at': '2026-09-01T00:00:00Z',
        'reservation_feedback_replies': [
          {
            'id': 'reply-1',
            'admin_name': 'Admin One',
            'message': 'Thanks for the review!',
            'created_at': '2026-09-02T00:00:00Z',
            'updated_at': '2026-09-03T00:00:00Z',
          },
        ],
      });

      expect(feedback.reply, isNotNull);
      expect(feedback.reply!.id, 'reply-1');
      expect(feedback.reply!.adminName, 'Admin One');
      expect(feedback.reply!.message, 'Thanks for the review!');
      expect(feedback.reply!.updatedAt, DateTime.parse('2026-09-03T00:00:00Z'));
    });

    test('parses from the flat reply_* columns feedback_admin_list projects', () {
      final feedback = BackendFeedback.fromJson({
        'id': 'feedback-2',
        'reservation_id': 'res-2',
        'facility_id': 'fac-1',
        'user_id': 'user-1',
        'rating': 4,
        'created_at': '2026-09-01T00:00:00Z',
        'updated_at': '2026-09-01T00:00:00Z',
        'reservation_admin_lane': 'internal',
        'reply_message': 'Appreciate the feedback.',
        'reply_admin_name': 'Admin Two',
        'reply_updated_at': '2026-09-05T00:00:00Z',
      });

      expect(feedback.reservationAdminLane, 'internal');
      expect(feedback.reply, isNotNull);
      expect(feedback.reply!.adminName, 'Admin Two');
      expect(feedback.reply!.message, 'Appreciate the feedback.');
    });

    test('is null when neither shape is present', () {
      final feedback = BackendFeedback.fromJson({
        'id': 'feedback-3',
        'reservation_id': 'res-3',
        'facility_id': 'fac-1',
        'user_id': 'user-1',
        'rating': 3,
        'created_at': '2026-09-01T00:00:00Z',
        'updated_at': '2026-09-01T00:00:00Z',
      });

      expect(feedback.reply, isNull);
    });
  });

  group('FeedbackLimits.reply bounds', () {
    test('mirror the reservation_feedback_replies.message CHECK constraint', () {
      expect(FeedbackLimits.replyMin, 3);
      expect(FeedbackLimits.replyMax, 1000);
    });
  });

  group('student feedback section', () {
    testWidgets('renders the admin reply under the renter\'s own review', (
      tester,
    ) async {
      final state = AppState();
      state.requests = [
        _reviewedRequest(
          reply: FeedbackReply(
            id: 'reply-1',
            adminName: 'Admin One',
            message: 'Thanks for flagging this, we fixed it.',
            createdAt: DateTime(2026, 9, 2),
            updatedAt: DateTime(2026, 9, 2),
          ),
        ),
        ...state.requests,
      ];

      await _pumpMyReservations(tester, state, size: const Size(1024, 900));

      expect(find.text('Reply from administrator'), findsOneWidget);
      expect(
        find.textContaining('Thanks for flagging this, we fixed it.'),
        findsOneWidget,
      );
    });

    testWidgets('is absent when the review has no reply yet', (tester) async {
      final state = AppState();
      state.requests = [_reviewedRequest(), ...state.requests];

      await _pumpMyReservations(tester, state, size: const Size(1024, 900));

      expect(find.text('Reply from administrator'), findsNothing);
    });
  });
}
