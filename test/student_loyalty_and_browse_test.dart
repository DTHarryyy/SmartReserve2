import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/calendar/calendar_screen.dart';
import 'package:smartreserve/features/loyalty/loyalty_admin_screen.dart';
import 'package:smartreserve/features/student/loyalty_page.dart';
import 'package:smartreserve/features/student/student_app.dart';
import 'package:smartreserve/features/users/users_screen.dart';
import 'package:smartreserve/model/facility.dart';
import 'package:smartreserve/model/loyalty.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/widgets/sr_controls.dart';

Future<void> _pumpScoped(
  WidgetTester tester,
  AppState state,
  Widget child, {
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
        home: child,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openAccountTab(WidgetTester tester) async {
  await tester.tap(find.text('Account').last);
  await tester.pumpAndSettle();
}

Future<void> _openCalendarTab(WidgetTester tester) async {
  await tester.tap(find.text('Calendar').last);
  await tester.pumpAndSettle();
}

FlutterExceptionHandler? _collectFlutterErrors(
  List<FlutterErrorDetails> errors,
) {
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  return previous;
}

void _restoreFlutterErrors(FlutterExceptionHandler? previous) {
  FlutterError.onError = previous;
}

void _makeGymplexCardDemanding(AppState state) {
  final gymplex = state.facilities.firstWhere((item) => item.id == 'f5');
  gymplex
    ..name = 'Gymplex'
    ..capacity = 4000
    ..hours = '08:00-19:00'
    ..days = 'Mon-Sun'
    ..state = FacilityState.active
    ..amenities = ['Power Outlets']
    ..ratingAverage = 4.8
    ..ratingCount = 124;
}

AppState _externalAdminState() => AppState()
  ..sessionProfile = SessionProfile(
    id: 'u10',
    email: 'g.villanueva@csu.edu.ph',
    fullName: 'Grace Villanueva',
    role: 'external_admin',
    campusClaim: 'none',
    campusId: null,
    unit: 'Business Affairs',
    verificationStatus: 'verified',
    onboardingComplete: true,
    accountStatus: 'active',
    accountAccessType: 'administrator',
    mustChangePassword: false,
    createdAt: DateTime(2025, 11),
  );

Future<void> _openNewDiscountDialog(
  WidgetTester tester,
  AppState state, {
  required Size size,
}) async {
  await _pumpScoped(tester, state, const LoyaltyAdminScreen(), size: size);
  await tester.tap(find.text('Discounts'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('New discount'));
  await tester.pumpAndSettle();
}

String _friendlyTestDate(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[value.month - 1]} ${value.day}, ${value.year}';
}

void main() {
  test(
    'loyalty point formatting keeps half-point precision only when needed',
    () {
      expect(formatPoints(0.5), '0.5');
      expect(formatPoints(1), '1');
      expect(formatPoints(2.5), '2.5');
      expect(formatPoints(10.0), '10');
    },
  );

  test('discount labels render fixed and percentage voucher values', () {
    final now = DateTime(2026, 8, 31);
    final fixed = LoyaltyDiscountOffer(
      id: 'fixed',
      name: 'PHP 100 off',
      requiredPoints: 2.5,
      discountKind: DiscountKind.fixedAmount,
      fixedAmountCentavos: 10000,
      validFrom: now,
      validUntil: now,
      createdAt: now,
      updatedAt: now,
    );
    final percent = LoyaltyDiscountOffer(
      id: 'percent',
      name: 'Ten percent',
      requiredPoints: 4,
      discountKind: DiscountKind.percentage,
      percentage: 10,
      validFrom: now,
      validUntil: now,
      createdAt: now,
      updatedAt: now,
    );

    expect(fixed.valueLabel, 'PHP 100.00 off');
    expect(percent.valueLabel, '10% off');
    expect(formatPoints(fixed.requiredPoints), '2.5');
  });

  testWidgets(
    'loyalty entry points are visible only for guest-priced renters',
    (tester) async {
      final verified = AppState();
      await verified.refreshLoyalty();
      await _pumpScoped(
        tester,
        verified,
        const StudentApp(),
        size: const Size(900, 760),
      );

      expect(find.byKey(const Key('student-loyalty-chip')), findsNothing);
      await _openAccountTab(tester);
      expect(find.byKey(const Key('student-loyalty-entry')), findsNothing);

      final guest = AppState()..signInAsUser('u5');
      await _pumpScoped(
        tester,
        guest,
        const StudentApp(),
        size: const Size(900, 760),
      );

      expect(find.byKey(const Key('student-loyalty-chip')), findsOneWidget);
      await _openAccountTab(tester);
      expect(find.byKey(const Key('student-loyalty-entry')), findsOneWidget);

      final pending = AppState()..signInAsUser('u3');
      await _pumpScoped(
        tester,
        pending,
        const StudentApp(),
        size: const Size(900, 760),
      );

      expect(find.byKey(const Key('student-loyalty-chip')), findsOneWidget);
    },
  );

  testWidgets(
    'stale loyalty navigation for verified renters shows unavailable',
    (tester) async {
      final state = AppState();
      await state.refreshLoyalty();

      await _pumpScoped(
        tester,
        state,
        const LoyaltyPage(),
        size: const Size(430, 760),
      );

      expect(
        find.text('Loyalty is available to guest renters'),
        findsOneWidget,
      );
      expect(find.text('Available balance'), findsNothing);
      expect(find.text('Redeem'), findsNothing);
    },
  );

  testWidgets('discount editor shows persistent labels and helpers', (
    tester,
  ) async {
    final state = _externalAdminState();

    await _openNewDiscountDialog(tester, state, size: const Size(1180, 840));

    expect(find.text('Discount details'), findsOneWidget);
    expect(find.textContaining('Discount name'), findsOneWidget);
    expect(
      find.text('Shown to renters when they claim this discount.'),
      findsOneWidget,
    );
    expect(find.text('Description'), findsOneWidget);
    expect(find.textContaining('Points required'), findsOneWidget);
    expect(find.text('Discount value'), findsOneWidget);
    expect(find.textContaining('Discount type'), findsOneWidget);
    expect(find.textContaining('Discount amount (PHP)'), findsOneWidget);
    expect(find.text('Applies to'), findsOneWidget);
    expect(find.textContaining('Eligible bookings'), findsOneWidget);
    expect(find.text('Availability period'), findsOneWidget);
    expect(find.textContaining('Valid from'), findsOneWidget);
    expect(find.textContaining('Valid until'), findsOneWidget);
    expect(find.text('Offer status'), findsOneWidget);
    expect(find.text('Required fields are marked *.'), findsOneWidget);
    expect(
      find.text('Active — renters can claim this discount'),
      findsOneWidget,
    );
  });

  testWidgets('discount editor pairs related fields on wide screens', (
    tester,
  ) async {
    final state = _externalAdminState();

    await _openNewDiscountDialog(tester, state, size: const Size(1180, 840));

    final typeTop = tester.getTopLeft(find.textContaining('Discount type')).dy;
    final amountTop = tester
        .getTopLeft(find.textContaining('Discount amount (PHP)'))
        .dy;
    final fromTop = tester.getTopLeft(find.textContaining('Valid from')).dy;
    final untilTop = tester.getTopLeft(find.textContaining('Valid until')).dy;

    expect((typeTop - amountTop).abs(), lessThan(2));
    expect((fromTop - untilTop).abs(), lessThan(2));
  });

  testWidgets('discount editor stacks paired fields on narrow screens', (
    tester,
  ) async {
    final state = _externalAdminState();

    await _openNewDiscountDialog(tester, state, size: const Size(430, 760));

    final typeTop = tester.getTopLeft(find.textContaining('Discount type')).dy;
    final amountTop = tester
        .getTopLeft(find.textContaining('Discount amount (PHP)'))
        .dy;

    expect(amountTop, greaterThan(typeTop + 20));
  });

  testWidgets('discount editor updates amount label for percentage discounts', (
    tester,
  ) async {
    final state = _externalAdminState();

    await _openNewDiscountDialog(tester, state, size: const Size(1180, 840));

    await tester.tap(find.text('Fixed PHP').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Percentage').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Discount percentage (%)'), findsOneWidget);
    expect(find.textContaining('Discount amount (PHP)'), findsNothing);
    expect(find.text('Enter a value from 1 to 100.'), findsOneWidget);
  });

  testWidgets('discount editor date picker updates the displayed date', (
    tester,
  ) async {
    final state = _externalAdminState();
    final now = DateTime.now();

    await _openNewDiscountDialog(tester, state, size: const Size(1180, 840));

    await tester.tap(
      find.text(_friendlyTestDate(DateTime(now.year, now.month, now.day))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('15').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(
      find.text(_friendlyTestDate(DateTime(now.year, now.month, 15))),
      findsOneWidget,
    );
  });

  testWidgets('discount editor shows field-specific validation errors', (
    tester,
  ) async {
    final state = _externalAdminState();

    await _openNewDiscountDialog(tester, state, size: const Size(1180, 840));

    await tester.tap(find.text('Save discount'));
    await tester.pumpAndSettle();

    expect(find.text('3 fields need attention'), findsOneWidget);
    expect(
      find.text('Please fix 3 highlighted fields before saving.'),
      findsOneWidget,
    );
    expect(find.text('Discount name is required.'), findsOneWidget);
    expect(find.text('Points required is required.'), findsOneWidget);
    expect(find.text('Discount amount is required.'), findsOneWidget);
  });

  testWidgets(
    'browse cards with ratings and amenities do not overflow compact',
    (tester) async {
      final errors = <FlutterErrorDetails>[];
      final previous = _collectFlutterErrors(errors);
      addTearDown(() => _restoreFlutterErrors(previous));

      final state = AppState();
      _makeGymplexCardDemanding(state);

      await _pumpScoped(
        tester,
        state,
        const StudentApp(),
        size: const Size(430, 760),
      );

      expect(find.text('Gymplex'), findsOneWidget);
      expect(
        errors.where(
          (error) =>
              error.exceptionAsString().contains('RenderFlex overflowed'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'browse cards with ratings and amenities do not overflow desktop',
    (tester) async {
      final errors = <FlutterErrorDetails>[];
      final previous = _collectFlutterErrors(errors);
      addTearDown(() => _restoreFlutterErrors(previous));

      final state = AppState();
      _makeGymplexCardDemanding(state);

      await _pumpScoped(
        tester,
        state,
        const StudentApp(),
        size: const Size(1180, 840),
      );

      expect(find.text('Gymplex'), findsOneWidget);
      expect(
        errors.where(
          (error) =>
              error.exceptionAsString().contains('RenderFlex overflowed'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets('browse card opens facility details instead of booking form', (
    tester,
  ) async {
    final state = AppState();
    final facility = state.bookableFacilities.first;

    await _pumpScoped(
      tester,
      state,
      const StudentApp(),
      size: const Size(1180, 840),
    );

    await tester.tap(
      find.bySemanticsLabel('View details for ${facility.name}'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Facility details'), findsOneWidget);
    expect(find.text('Request this facility'), findsNothing);
    expect(
      find.bySemanticsLabel('Reserve now for ${facility.name}'),
      findsWidgets,
    );
  });

  testWidgets('browse card reserve CTA opens the booking form directly', (
    tester,
  ) async {
    final state = AppState();
    final facility = state.bookableFacilities.first;

    await _pumpScoped(
      tester,
      state,
      const StudentApp(),
      size: const Size(1180, 840),
    );

    await tester.tap(
      find.byKey(ValueKey('facility-card-reserve-${facility.id}')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Request this facility'), findsOneWidget);
  });

  testWidgets(
    'unavailable browse card keeps details but disables reserve CTA',
    (tester) async {
      final state = AppState();
      final facility = state.facilities.first;
      facility.state = FacilityState.maintenance;

      await _pumpScoped(
        tester,
        state,
        const StudentApp(),
        size: const Size(1180, 840),
      );

      final button = tester.widget<SrButton>(
        find.byKey(ValueKey('facility-card-reserve-${facility.id}')),
      );
      expect(button.onPressed, isNull);

      await tester.tap(
        find.bySemanticsLabel('View details for ${facility.name}'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Facility details'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Reserve now for ${facility.name}'),
        findsWidgets,
      );
    },
  );

  testWidgets(
    'calendar tab is available for active users in every verification state',
    (tester) async {
      for (final userId in ['u1', 'u3', 'u5', 'u6']) {
        final state = AppState()..signInAsUser(userId);
        await _pumpScoped(
          tester,
          state,
          const StudentApp(),
          size: const Size(900, 760),
        );

        expect(find.text('Calendar'), findsWidgets);
      }
    },
  );

  testWidgets('public calendar masks reservation details on compact layout', (
    tester,
  ) async {
    final state = AppState();
    state.userCalendarAnchor = DateTime(2026, 7, 28);
    await state.refreshUserCalendar();

    await _pumpScoped(
      tester,
      state,
      const StudentApp(),
      size: const Size(430, 760),
    );
    await _openCalendarTab(tester);

    expect(find.text('Reserved'), findsWidgets);
    expect(find.textContaining('Prof. Bautista'), findsNothing);
    expect(find.textContaining('IT 3A'), findsNothing);
    expect(find.textContaining('Nursing orientation'), findsNothing);
    expect(find.textContaining('Dean Villamor'), findsNothing);

    await tester.tap(find.text('Reserved').first);
    await tester.pumpAndSettle();
    expect(find.text('Reservation details'), findsNothing);
    expect(find.text('Open reservation'), findsNothing);
  });

  testWidgets('public calendar facility filter refreshes visible slots', (
    tester,
  ) async {
    final state = AppState();
    state.userCalendarAnchor = DateTime(2026, 7, 28);
    await state.refreshUserCalendar();

    await _pumpScoped(
      tester,
      state,
      const PublicCalendarScreen(),
      size: const Size(430, 760),
    );

    expect(find.textContaining('Computer Laboratory 1'), findsWidgets);

    state.setUserCalendarFacilityFilter('University Auditorium');
    await tester.pumpAndSettle();

    expect(find.textContaining('University Auditorium'), findsWidgets);
    expect(find.textContaining('Computer Laboratory 1'), findsNothing);
  });

  testWidgets('admin calendar keeps reservation controls', (tester) async {
    final state = AppState();

    await _pumpScoped(
      tester,
      state,
      const CalendarScreen(),
      size: const Size(1180, 840),
    );

    expect(find.text('Search reservations'), findsOneWidget);
    expect(find.text('Needs decision'), findsWidgets);
    expect(find.text('Confirmed'), findsWidgets);
  });

  testWidgets('external admin clients page uses shared directory wording', (
    tester,
  ) async {
    final state = _externalAdminState();

    await _pumpScoped(
      tester,
      state,
      const UsersScreen(),
      size: const Size(1180, 840),
    );

    expect(find.text('Clients'), findsOneWidget);
    expect(
      find.text(
        'This shared directory includes all active guest or unverified clients with reservation or payment activity. Campus records, administrator accounts, and verification documents are excluded.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('assigned facilities'), findsNothing);
  });
}
