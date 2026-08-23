import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/student/student_app.dart';
import 'package:smartreserve/model/facility.dart';
import 'package:smartreserve/model/facility_photo.dart';
import 'package:smartreserve/widgets/filter_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

SessionProfile widgetProfile({
  String verificationStatus = 'verified',
  String role = 'user',
}) => SessionProfile(
  id: '00000000-0000-0000-0000-000000000100',
  email: 'roel@example.com',
  fullName: 'Roel Dela Cruz',
  role: role,
  campusClaim: 'student',
  campusId: '2026-00123',
  unit: 'BS Information Technology',
  verificationStatus: verificationStatus,
  onboardingComplete: true,
  accountStatus: 'active',
  createdAt: DateTime.utc(2026, 8, 7, 12),
);

Future<void> pumpStudentApp(
  WidgetTester tester, {
  required AppState state,
  Size size = const Size(1200, 900),
  bool settle = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: const MaterialApp(home: Scaffold(body: StudentApp())),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('desktop uses the simple identity header and bottom navigation', (
    tester,
  ) async {
    final state = AppState();
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state);

    expect(find.text('Roel Dela Cruz'), findsOneWidget);
    expect(find.text('roel@example.com'), findsOneWidget);
    expect(find.text('VERIFIED'), findsOneWidget);
    expect(find.text('You are verified'), findsOneWidget);
    expect(find.text('Admin'), findsNothing);
    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);

    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    expect(find.text('Your details'), findsOneWidget);
  });

  testWidgets(
    'unavailable public facility remains browsable but not reservable',
    (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      final facility = state.facilities.first..bookableForCurrentUser = false;
      await state.applyBackendProfile(widgetProfile());

      await pumpStudentApp(tester, state: state);

      expect(find.text(facility.name), findsOneWidget);
      expect(find.text('Unavailable · no administrator'), findsOneWidget);
      await tester.tap(find.text(facility.name));
      await tester.pumpAndSettle();

      expect(find.text('Reservations unavailable'), findsOneWidget);
      expect(find.text('Send request to the registrar'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'browse distinguishes loading, load failure, and an empty catalogue',
    (tester) async {
      final state = AppState(useDemoData: false);
      addTearDown(state.dispose);
      await state.applyBackendProfile(widgetProfile());

      state.facilitiesLoading = true;
      await pumpStudentApp(tester, state: state, settle: false);
      expect(find.text('Loading facilities'), findsOneWidget);

      state
        ..facilitiesLoading = false
        ..facilitiesError = 'Facilities could not be loaded.';
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Facilities could not be loaded'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      state.facilitiesError = null;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('No public facilities yet'), findsOneWidget);
    },
  );

  testWidgets('a category removed by refresh falls back to all facilities', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    await state.applyBackendProfile(widgetProfile());
    final removedCategory = state.browsableFacilities.first.category;
    final remaining = state.browsableFacilities.firstWhere(
      (facility) => facility.category != removedCategory,
    );
    await pumpStudentApp(tester, state: state);

    await tester.tap(
      find.bySemanticsLabel(
        RegExp('Show ${RegExp.escape(removedCategory)} facilities'),
      ),
    );
    await tester.pumpAndSettle();
    for (final facility in state.facilities) {
      if (facility.category == removedCategory) {
        facility.state = FacilityState.draft;
      }
    }
    state.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('No facilities match'), findsNothing);
    expect(find.text(remaining.name), findsOneWidget);
  });

  testWidgets('verification banners can be dismissed permanently', (
    tester,
  ) async {
    final state = AppState();
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state);

    expect(find.text('You are verified'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss membership message'));
    await tester.pumpAndSettle();
    expect(find.text('You are verified'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await pumpStudentApp(tester, state: state);
    expect(find.text('You are verified'), findsNothing);
  });

  testWidgets('mobile keeps name and email with a compact pending badge', (
    tester,
  ) async {
    final state = AppState();
    await state.applyBackendProfile(
      widgetProfile(verificationStatus: 'pending'),
    );
    await pumpStudentApp(tester, state: state, size: const Size(360, 760));

    expect(find.text('Roel Dela Cruz'), findsOneWidget);
    expect(find.text('roel@example.com'), findsOneWidget);
    expect(find.text('IN PROCESS'), findsOneWidget);
    expect(find.text('Verification in process'), findsOneWidget);
    expect(find.text('You are booking at the external rate'), findsNothing);
    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Filters'), findsOneWidget);
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    final category = find.byWidgetPredicate(
      (widget) =>
          widget is FilterSelect &&
          widget.semanticLabel == 'Filter by category',
    );
    final capacity = find.byWidgetPredicate(
      (widget) =>
          widget is FilterSelect &&
          widget.semanticLabel == 'Filter by minimum capacity',
    );
    expect(category, findsOneWidget);
    expect(capacity, findsOneWidget);
    expect(
      tester.getSize(category).width,
      closeTo(tester.getSize(capacity).width, 1),
    );
    expect(find.text('Amenities'), findsOneWidget);
    expect(find.text('Filter facilities'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('external users do not see a membership banner', (tester) async {
    final state = AppState();
    await state.applyBackendProfile(
      widgetProfile(verificationStatus: 'none', role: 'user'),
    );
    await pumpStudentApp(tester, state: state);

    expect(find.text('You are verified'), findsNothing);
    expect(find.text('Verification in process'), findsNothing);
  });

  testWidgets('facility filters combine and clear correctly', (tester) async {
    final state = AppState();
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state);

    expect(find.text('5 of 5'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'auditorium');
    await tester.pump();
    expect(find.text('University Auditorium'), findsOneWidget);
    expect(find.text('Computer Laboratory 1'), findsNothing);

    await tester.tap(find.text('Clear filters'));
    await tester.pump();
    await tester.tap(find.text('Any capacity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('500+ seats').last);
    await tester.pumpAndSettle();
    expect(find.text('Main Court'), findsOneWidget);

    await tester.tap(find.text('Clear filters'));
    await tester.pump();
    await tester.tap(find.text('Amenities'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projector').last);
    await tester.pumpAndSettle();
    expect(find.text('Computer Laboratory 1'), findsOneWidget);
    expect(find.text('University Auditorium'), findsOneWidget);

    await tester.tap(find.text('Amenities (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Power Outlets').last);
    await tester.pumpAndSettle();
    expect(find.text('Computer Laboratory 1'), findsOneWidget);
    expect(find.text('University Auditorium'), findsNothing);

    await tester.tap(find.text('Clear filters'));
    await tester.pump();
    expect(find.text('5 of 5'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'does not exist');
    await tester.pump();
    expect(find.text('No facilities match'), findsOneWidget);

    await tester.tap(find.text('Clear filters').last);
    await tester.pump();
    expect(find.text('5 of 5'), findsNothing);
  });

  testWidgets('category filter narrows the facility catalogue', (tester) async {
    final state = AppState();
    await state.applyBackendProfile(widgetProfile());
    await pumpStudentApp(tester, state: state);

    await tester.tap(find.text('All categories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auditorium').last);
    await tester.pumpAndSettle();

    expect(find.text('University Auditorium'), findsOneWidget);
    expect(find.text('Main Court'), findsNothing);
  });

  testWidgets('facility dialog shows every photo and booking detail', (
    tester,
  ) async {
    final state = AppState();
    await state.applyBackendProfile(widgetProfile());
    final facility = state.facilities.first;
    facility.photos = [
      FacilityPhoto.placeholder(11),
      FacilityPhoto.placeholder(12),
      FacilityPhoto.placeholder(13),
    ];
    facility.street = 'University Avenue';
    facility.barangay = 'Macanaya';
    facility.municipality = 'Aparri';
    facility.province = 'Cagayan';
    facility.region = 'Region II';
    facility.country = 'Philippines';

    await pumpStudentApp(tester, state: state);
    await tester.tap(find.text('Computer Laboratory 1'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.text('1 / 3 PHOTOS'), findsOneWidget);
    expect(find.text('Facility details'), findsOneWidget);
    expect(find.text('Request this facility'), findsOneWidget);
    expect(find.text('07:00–19:00'), findsOneWidget);
    expect(find.text('30 days ahead'), findsOneWidget);
    expect(find.text('15 minutes'), findsOneWidget);
    expect(find.textContaining('University Avenue'), findsOneWidget);
    expect(find.text('Open map ↗'), findsOneWidget);
    expect(find.text('PWD Accessibility'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('facility-photo-thumbnail-1')));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3 PHOTOS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('amenity picker', () {
    testWidgets('opens without crashing and lists facility amenities only', (
      tester,
    ) async {
      final state = AppState();
      await state.applyBackendProfile(widgetProfile());

      await pumpStudentApp(tester, state: state);
      await tester.tap(find.text('Computer Laboratory 1'));
      await tester.pumpAndSettle();

      final trigger = find.byKey(const ValueKey('amenity-request-trigger'));
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();

      // The reported crash: RenderShrinkWrappingViewport does not support
      // returning intrinsic dimensions, thrown by a ListView inside the
      // popup menu's IntrinsicWidth wrapper.
      expect(tester.takeException(), isNull);
      expect(find.text('IN THIS ROOM'), findsOneWidget);
      expect(find.text('OTHER'), findsNothing);
      expect(find.byKey(const ValueKey('amenity-row-Wi-Fi')), findsOneWidget);
      expect(find.byKey(const ValueKey('amenity-row-Generator')), findsNothing);
    });

    testWidgets('checking rows keeps the popover open and adds chips', (
      tester,
    ) async {
      final state = AppState();
      await state.applyBackendProfile(widgetProfile());

      await pumpStudentApp(tester, state: state);
      await tester.tap(find.text('Computer Laboratory 1'));
      await tester.pumpAndSettle();

      final trigger = find.byKey(const ValueKey('amenity-request-trigger'));
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();

      final wifiRow = find.byKey(const ValueKey('amenity-row-Wi-Fi'));
      await tester.tap(wifiRow);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('amenity-chip-Wi-Fi')), findsOneWidget);
      // The row is still present, proving the popover did not dismiss.
      expect(wifiRow, findsOneWidget);

      final acRow = find.byKey(const ValueKey('amenity-row-Air Conditioning'));
      await tester.tap(acRow);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('amenity-chip-Air Conditioning')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('amenity-chip-Wi-Fi')), findsOneWidget);
    });

    testWidgets('tapping a checked row again removes its chip', (tester) async {
      final state = AppState();
      await state.applyBackendProfile(widgetProfile());

      await pumpStudentApp(tester, state: state);
      await tester.tap(find.text('Computer Laboratory 1'));
      await tester.pumpAndSettle();

      final trigger = find.byKey(const ValueKey('amenity-request-trigger'));
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();

      final wifiRow = find.byKey(const ValueKey('amenity-row-Wi-Fi'));
      await tester.tap(wifiRow);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('amenity-chip-Wi-Fi')), findsOneWidget);

      await tester.tap(wifiRow);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('amenity-chip-Wi-Fi')), findsNothing);
    });

    testWidgets('the chip remove button clears the selection', (tester) async {
      final state = AppState();
      await state.applyBackendProfile(widgetProfile());

      await pumpStudentApp(tester, state: state);
      await tester.tap(find.text('Computer Laboratory 1'));
      await tester.pumpAndSettle();

      final trigger = find.byKey(const ValueKey('amenity-request-trigger'));
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('amenity-row-Wi-Fi')));
      await tester.pumpAndSettle();
      // The popover's modal barrier absorbs pointer events over the whole
      // screen while open, so the chip underneath can't be tapped yet.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      final chip = find.byKey(const ValueKey('amenity-chip-Wi-Fi'));
      expect(chip, findsOneWidget);
      final removeButton = find.descendant(
        of: chip,
        matching: find.byIcon(Icons.close_rounded),
      );
      expect(removeButton, findsOneWidget);

      await tester.tap(removeButton);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(chip, findsNothing);
    });

    testWidgets('the trigger renders as the last item after the chips', (
      tester,
    ) async {
      final state = AppState();
      await state.applyBackendProfile(widgetProfile());

      await pumpStudentApp(tester, state: state);
      await tester.tap(find.text('Computer Laboratory 1'));
      await tester.pumpAndSettle();

      final trigger = find.byKey(const ValueKey('amenity-request-trigger'));
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('amenity-row-Wi-Fi')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      // Checked against the Wrap's own children order rather than screen
      // position: a narrow column can wrap the trigger onto its own line,
      // where it lands at the same x as the first chip.
      final wrap = tester.widget<Wrap>(
        find.byKey(const ValueKey('amenity-field-wrap')),
      );
      expect(wrap.children, isNotEmpty);
      expect(wrap.children.last, isA<Padding>());
      expect(
        wrap.children.take(wrap.children.length - 1),
        isNot(contains(isA<Padding>())),
      );
    });

    testWidgets('opens without overflow or crash on a narrow phone', (
      tester,
    ) async {
      final state = AppState();
      await state.applyBackendProfile(widgetProfile());

      await pumpStudentApp(tester, state: state, size: const Size(360, 760));
      await tester.tap(find.text('Computer Laboratory 1'));
      await tester.pumpAndSettle();

      final trigger = find.byKey(const ValueKey('amenity-request-trigger'));
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('amenity-row-Wi-Fi')), findsOneWidget);
    });
  });

  testWidgets('facility opens as a back-enabled page on a small phone', (
    tester,
  ) async {
    final state = AppState();
    await state.applyBackendProfile(widgetProfile());
    state.facilities.first.photos = [
      FacilityPhoto.placeholder(21),
      FacilityPhoto.placeholder(22),
    ];

    await pumpStudentApp(tester, state: state, size: const Size(360, 760));
    await tester.tap(find.text('Computer Laboratory 1'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Close'), findsNothing);
    expect(find.text('1 / 2 PHOTOS'), findsOneWidget);
    expect(find.text('Facility details'), findsOneWidget);
    expect(find.text('Request this facility'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final dateRect = tester.getRect(find.text('Date'));
    final attendeesRect = tester.getRect(find.text('Attendees'));
    final fromRect = tester.getRect(find.text('From'));
    final toRect = tester.getRect(find.text('To'));
    expect(dateRect.top, closeTo(attendeesRect.top, 1));
    expect(fromRect.top, closeTo(toRect.top, 1));

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Computer Laboratory 1'), findsOneWidget);
  });

  group('attendee capacity', () {
    Future<void> openBookingSheet(WidgetTester tester) async {
      final state = AppState();
      await state.applyBackendProfile(widgetProfile());
      await pumpStudentApp(tester, state: state);
      await tester.tap(find.text('Computer Laboratory 1'));
      await tester.pumpAndSettle();
    }

    testWidgets('a count above capacity blocks the submit and says why', (
      tester,
    ) async {
      await openBookingSheet(tester);

      // Computer Laboratory 1 seats 40.
      final attendees = find.bySemanticsLabel('Attendees');
      await tester.enterText(attendees, '120');
      await tester.pumpAndSettle();

      // The advisory appears as soon as the count goes over.
      expect(
        find.textContaining('120 people in a 40-seat room'),
        findsOneWidget,
      );

      final submit = find.text('Send request to the registrar');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Computer Laboratory 1 seats 40'),
        findsOneWidget,
      );
      // Still on the form — nothing was sent.
      expect(submit, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a count within capacity clears the blocking message', (
      tester,
    ) async {
      await openBookingSheet(tester);

      final attendees = find.bySemanticsLabel('Attendees');
      await tester.enterText(attendees, '120');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('120 people in a 40-seat room'),
        findsOneWidget,
      );

      await tester.enterText(attendees, '30');
      await tester.pumpAndSettle();

      expect(find.textContaining('-seat room'), findsNothing);
      expect(find.textContaining('seats 40'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the attendees field refuses non-numeric input', (
      tester,
    ) async {
      await openBookingSheet(tester);

      final attendees = find.bySemanticsLabel('Attendees');
      await tester.enterText(attendees, '12abc-3');
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, '123'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
