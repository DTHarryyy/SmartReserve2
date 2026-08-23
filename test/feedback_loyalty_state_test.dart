import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/model/reservation.dart';

void main() {
  group('canLeaveFeedback eligibility', () {
    test(
      'true only for a reservation with a genuinely completed occurrence',
      () {
        final state = _state(_FakeBackend());
        addTearDown(state.dispose);
        expect(state.canLeaveFeedback(_completedRequest()), isTrue);
      },
    );

    test('false for a confirmed (not yet completed) reservation', () {
      final state = _state(_FakeBackend());
      addTearDown(state.dispose);
      final request = _completedRequest(
        status: ReservationLifecycleStatus.confirmed,
      );
      expect(state.canLeaveFeedback(request), isFalse);
    });

    test(
      'false when reservation_status is completed but every occurrence is a '
      'no-show (the all-no-show gap called out in the migration)',
      () {
        final state = _state(_FakeBackend());
        addTearDown(state.dispose);
        final request = _completedRequest(occurrenceStage: BookingStage.noShow);
        expect(state.canLeaveFeedback(request), isFalse);
      },
    );

    test('false once feedback has already been left', () {
      final state = _state(_FakeBackend());
      addTearDown(state.dispose);
      final request = _completedRequest()..feedbackRating = 5;
      expect(state.canLeaveFeedback(request), isFalse);
    });
  });

  test(
    'submitFeedback mutates the reservation in place before the backend '
    'refresh resolves, and guards against a double submit',
    () async {
      final backend = _FakeBackend();
      final state = _state(backend);
      addTearDown(state.dispose);
      final request = _completedRequest();

      final call = backend.startFeedbackSubmission();
      final future = state.submitFeedback(request, rating: 4, comment: 'Good');

      // A second submit while the first is still in flight is a no-op.
      final duplicate = state.submitFeedback(request, rating: 1);
      expect(await duplicate, isFalse);
      expect(state.feedbackSubmitting, contains(request.id));

      call.complete(
        BackendFeedback(
          id: 'fb1',
          reservationId: request.id,
          facilityId: request.facilityId!,
          userId: 'u1',
          rating: 4,
          comment: 'Good',
          createdAt: DateTime(2026, 8, 1),
          updatedAt: DateTime(2026, 8, 1),
        ),
      );

      expect(await future, isTrue);
      expect(request.feedbackRating, 4);
      expect(request.feedbackComment, 'Good');
      expect(state.feedbackSubmitting, isNot(contains(request.id)));
      expect(backend.feedbackSubmissions, 1);
    },
  );

  test(
    'a failed feedback submission clears the pending flag and does not '
    'mutate the reservation',
    () async {
      final backend = _FakeBackend()..failNextFeedback = true;
      final state = _state(backend);
      addTearDown(state.dispose);
      final request = _completedRequest();

      final ok = await state.submitFeedback(request, rating: 3);

      expect(ok, isFalse);
      expect(request.feedbackRating, isNull);
      expect(state.feedbackSubmitting, isEmpty);
    },
  );

  test(
    'redeemReward is guarded against a double tap on the same reward',
    () async {
      final backend = _FakeBackend();
      final state = _state(backend);
      addTearDown(state.dispose);
      final reward = BackendLoyaltyReward(
        id: 'r1',
        name: 'Sticker pack',
        pointsCost: 10,
        createdAt: DateTime(2026, 8, 1),
        updatedAt: DateTime(2026, 8, 1),
      ).toModel();

      final call = backend.startRedemption();
      final first = state.redeemReward(reward);
      final second = state.redeemReward(reward);

      expect(await second, isFalse);
      call.complete(
        BackendLoyaltyRedemption(
          id: 'red1',
          userId: 'u1',
          rewardId: reward.id,
          rewardName: reward.name,
          pointsSpent: reward.pointsCost,
          status: 'issued',
          redemptionCode: 'ABCD1234',
          createdAt: DateTime(2026, 8, 1),
        ),
      );
      expect(await first, isTrue);
      expect(backend.redemptions, 1);
    },
  );

  test(
    'the displayed balance always comes from the server response, never '
    'from a local sum',
    () async {
      final backend = _FakeBackend();
      final state = _state(backend);
      addTearDown(state.dispose);

      await state.refreshLoyalty();

      expect(state.loyalty?.balance, 42);
    },
  );
}

AppState _state(_FakeBackend backend) {
  final state = AppState(useDemoData: false)..configureBackend(backend);
  state.sessionProfile = const SessionProfile(
    id: 'u1',
    email: 'jomar@example.com',
    fullName: 'Jomar Padilla',
    role: 'user',
    campusClaim: 'student',
    campusId: '2022-01458',
    unit: 'BS Information Technology',
    verificationStatus: 'verified',
    onboardingComplete: true,
    accountStatus: 'active',
    createdAt: null,
  );
  return state;
}

ReservationRequest _completedRequest({
  ReservationLifecycleStatus status = ReservationLifecycleStatus.completed,
  BookingStage occurrenceStage = BookingStage.completed,
}) => ReservationRequest(
  id: 'req1',
  facility: 'Computer Laboratory 1',
  building: 'CICS',
  room: 'CICS-201',
  capacity: 40,
  requester: 'Jomar Padilla',
  requesterId: 'u1',
  facilityId: 'fac1',
  role: 'User',
  org: 'JPCS',
  purpose: 'Review session',
  date: 'Tue 21 Jul',
  start: '13:00',
  end: '15:00',
  heads: 10,
  submitted: '9 days ago',
  urgent: false,
  attachments: 0,
  noShows: 0,
  status: RequestStatus.approved,
  lifecycleStatus: status,
  occurrences: [
    ReservationOccurrence(
      id: 'occ1',
      startsAt: DateTime(2026, 7, 21, 13),
      endsAt: DateTime(2026, 7, 21, 15),
      bookingState: 'booked',
      stage: occurrenceStage,
    ),
  ],
);

class _FakeBackend implements SmartReserveBackend, SmartReserveCoreBackend {
  int feedbackSubmissions = 0;
  int redemptions = 0;
  bool failNextFeedback = false;
  Completer<BackendFeedback>? _feedbackCall;
  Completer<BackendLoyaltyRedemption>? _redemptionCall;

  Completer<BackendFeedback> startFeedbackSubmission() {
    final call = Completer<BackendFeedback>();
    _feedbackCall = call;
    return call;
  }

  Completer<BackendLoyaltyRedemption> startRedemption() {
    final call = Completer<BackendLoyaltyRedemption>();
    _redemptionCall = call;
    return call;
  }

  @override
  Future<BackendFeedback> submitFeedback({
    required String reservationId,
    required int rating,
    String comment = '',
    int? cleanliness,
    int? condition,
    int? equipment,
  }) async {
    feedbackSubmissions++;
    if (failNextFeedback) {
      throw Exception('PostgrestException(message: Feedback opens once the '
          'reservation is completed, code: 22023)');
    }
    final call = _feedbackCall ??= Completer<BackendFeedback>()
      ..complete(
        BackendFeedback(
          id: 'fb-auto',
          reservationId: reservationId,
          facilityId: 'fac1',
          userId: 'u1',
          rating: rating,
          comment: comment,
          createdAt: DateTime(2026, 8, 1),
          updatedAt: DateTime(2026, 8, 1),
        ),
      );
    return call.future;
  }

  @override
  Future<BackendLoyaltyRedemption> redeemLoyaltyReward(String rewardId) async {
    redemptions++;
    final call = _redemptionCall ??= Completer<BackendLoyaltyRedemption>()
      ..complete(
        BackendLoyaltyRedemption(
          id: 'red-auto',
          userId: 'u1',
          rewardId: rewardId,
          rewardName: 'Reward',
          pointsSpent: 10,
          status: 'issued',
          redemptionCode: 'AUTO0000',
          createdAt: DateTime(2026, 8, 1),
        ),
      );
    return call.future;
  }

  @override
  Future<BackendLoyaltySummary> loyaltySummary() async => BackendLoyaltySummary(
    balance: 42,
    lifetimeEarned: 42,
    lifetimeRedeemed: 0,
    rules: const {'reservation_completed': 10, 'feedback_submitted': 5},
  );

  @override
  Stream<List<BackendLoyaltyTransaction>> loyaltyTransactionStream() =>
      const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
