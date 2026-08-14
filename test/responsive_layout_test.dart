import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_shell.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/app/app_view.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/auth/auth_controller.dart';
import 'package:smartreserve/features/auth/auth_screen.dart';
import 'package:smartreserve/features/student/student_app.dart';
import 'package:smartreserve/model/facility_photo.dart';
import 'package:smartreserve/model/notice.dart';
import 'package:smartreserve/widgets/app_header.dart';
import 'package:smartreserve/widgets/notices.dart';
import 'package:smartreserve/widgets/toast_host.dart';

const _viewports = <Size>[
  Size(320, 720),
  Size(360, 760),
  Size(375, 812),
  Size(390, 844),
  Size(412, 915),
  Size(480, 840),
  Size(480, 320),
  Size(600, 900),
  Size(760, 360),
  Size(768, 1024),
  Size(820, 1180),
  Size(844, 390),
  Size(1024, 768),
  Size(1280, 900),
  Size(1440, 900),
  Size(1920, 1080),
];

const _adminViews = <AppView>[
  AppView.facilities,
  AppView.addFacility,
  AppView.reservations,
  AppView.calendar,
  AppView.verifications,
  AppView.users,
  AppView.reports,
  AppView.audit,
  AppView.notes,
  AppView.profile,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('all admin modules render throughout the viewport matrix', (
    tester,
  ) async {
    final state = await _adminState();
    addTearDown(state.dispose);
    await _setViewport(tester, _viewports.first);
    await tester.pumpWidget(_adminApp(state));

    for (final size in _viewports) {
      tester.view.physicalSize = size;
      for (final view in _adminViews) {
        state.goTo(view);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        final error = tester.takeException();
        expect(
          error,
          isNull,
          reason:
              '${view.name} overflowed or threw at ${size.width}×${size.height}',
        );
      }
    }
  });

  testWidgets('compact records, drawer, calendar agenda, and dialog adapt', (
    tester,
  ) async {
    final state = await _adminState();
    addTearDown(state.dispose);
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_adminApp(state));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('facility-compact-f1')), findsOneWidget);
    expect(find.byKey(const Key('record-table-header')), findsNothing);

    await tester.tap(find.byTooltip('Sections'));
    await tester.pumpAndSettle();
    expect(find.text('Reservations'), findsOneWidget);
    Navigator.of(tester.element(find.text('Reservations').first)).pop();
    await tester.pumpAndSettle();

    state.goTo(AppView.calendar);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('compact-calendar-agenda')), findsOneWidget);

    state.goTo(AppView.facilities);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Computer Laboratory 1').first);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Dialog)).width, closeTo(390, 1));
    expect(tester.getSize(find.byType(Dialog)).height, closeTo(844, 1));

    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded records retain table presentation', (tester) async {
    final state = await _adminState();
    addTearDown(state.dispose);
    await _setViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(_adminApp(state));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('record-table-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('facility-compact-f1')), findsNothing);
    expect(find.byTooltip('Sections'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('global toasts stay at the top-right across admin layouts', (
    tester,
  ) async {
    final state = await _adminState();
    addTearDown(state.dispose);
    await _setViewport(tester, const Size(1280, 900));
    await tester.pumpWidget(_adminApp(state));

    for (final size in const [Size(1280, 900), Size(390, 844)]) {
      tester.view.physicalSize = size;
      state.showToast(
        const ToastMessage(
          'This responsive toast is intentionally long enough to exercise '
          'the available horizontal space on a compact screen.',
        ),
        duration: const Duration(seconds: 1),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final toastRect = tester.getRect(find.byType(SrToast));
      final headerRect = tester.getRect(find.byType(AppHeader));
      expect(toastRect.top, greaterThanOrEqualTo(headerRect.bottom));
      expect(toastRect.top, lessThan(size.height / 2));
      expect(toastRect.right, closeTo(size.width - 22, 0.1));
      if (size.width == 390) {
        expect(toastRect.left, closeTo(22, 0.1));
      }
      expect(tester.takeException(), isNull);
    }
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('top toast and bottom undo bar remain independently visible', (
    tester,
  ) async {
    final state = await _adminState();
    addTearDown(state.dispose);
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_adminApp(state));

    state
      ..offerUndo(
        UndoOffer(label: 'Reservation updated.', onUndo: () {}),
        window: const Duration(seconds: 1),
      )
      ..showToast(
        const ToastMessage('Changes saved.'),
        duration: const Duration(seconds: 1),
      );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(SrToast), findsOneWidget);
    expect(find.byType(UndoBar), findsOneWidget);
    expect(
      tester.getRect(find.byType(SrToast)).bottom,
      lessThan(tester.getRect(find.byType(UndoBar)).top),
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('non-admin toast uses the top safe-area content inset', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    await _setViewport(tester, const Size(390, 844));
    state.showToast(
      const ToastMessage('Confirmation code sent.'),
      duration: const Duration(seconds: 1),
    );

    await tester.pumpWidget(_adminApp(state));
    await tester.pump(const Duration(milliseconds: 250));

    final toastRect = tester.getRect(find.byType(SrToast));
    expect(toastRect.top, closeTo(22, 0.1));
    expect(toastRect.right, closeTo(368, 0.1));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('admin facility gallery swipes and exposes every photo', (
    tester,
  ) async {
    final state = await _adminState();
    addTearDown(state.dispose);
    final facility = state.facilities.first;
    facility.photos = [
      for (var i = 0; i < 8; i++) FacilityPhoto.placeholder(40 + i),
    ];

    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_adminApp(state));
    await tester.pumpAndSettle();

    expect(find.text('VERIFIED'), findsNothing);
    await tester.tap(find.text(facility.name).first);
    await tester.pumpAndSettle();

    expect(find.text('1 / 8 PHOTOS'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('admin-facility-photo-thumbnails')),
      findsOneWidget,
    );
    expect(find.text('Edit facility'), findsOneWidget);
    expect(find.text('VERIFIED'), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('admin-facility-photo-pages')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 / 8 PHOTOS'), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('admin-facility-photo-thumbnails')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('admin-facility-photo-thumbnail-7')),
    );
    await tester.pumpAndSettle();
    expect(find.text('8 / 8 PHOTOS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('admin facility gallery handles empty and single photo states', (
    tester,
  ) async {
    final state = await _adminState();
    addTearDown(state.dispose);
    final facility = state.facilities.first..photos = [];

    await _setViewport(tester, const Size(320, 720));
    await tester.pumpWidget(_adminApp(state));
    await tester.pumpAndSettle();
    await tester.tap(find.text(facility.name).first);
    await tester.pumpAndSettle();

    expect(find.text('NO PHOTOS'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('admin-facility-photo-thumbnails')),
      findsNothing,
    );
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    facility.photos = [FacilityPhoto.placeholder(99)];
    await tester.tap(find.text(facility.name).first);
    await tester.pumpAndSettle();
    expect(find.text('1 / 1 PHOTOS'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('admin-facility-photo-thumbnails')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('long realistic labels remain stable on a small phone', (
    tester,
  ) async {
    final state = await _adminState();
    addTearDown(state.dispose);
    state.facilities.first
      ..name = 'College of Fisheries Multi-Purpose Collaboration Laboratory'
      ..building = 'College of Fisheries and Marine Sciences Annex Building';
    state.accounts.first
      ..name = 'Maria Consuelo de la Cruz-Santillan the Third'
      ..email = 'maria.consuelodelacruz.santillan@students.csu-aparri.edu.ph';
    await _setViewport(tester, const Size(320, 720));
    await tester.pumpWidget(_adminApp(state));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    state.goTo(AppView.users);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('auth steps remain stable across representative window classes', (
    tester,
  ) async {
    final state = AppState();
    final controller = AuthController(state);
    addTearDown(controller.dispose);
    addTearDown(state.dispose);

    for (final size in const [
      Size(320, 720),
      Size(480, 320),
      Size(600, 900),
      Size(760, 360),
      Size(1024, 768),
      Size(1920, 1080),
    ]) {
      await _setViewport(tester, size, registerTearDown: false);
      for (final step in AuthStep.values) {
        controller.goTo(step);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AuthScreen(controller: controller, state: state),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final error = tester.takeException();
        expect(
          error,
          isNull,
          reason: '${step.name} failed at ${size.width}×${size.height}',
        );
      }
    }
  });

  testWidgets('student Assistant tab renders across the viewport matrix', (
    tester,
  ) async {
    // Student tabs get no coverage from the admin-only matrix above; this
    // is the cheapest catch for composer/chip-row overflow at narrow and
    // landscape sizes, where header + thread + chips + composer + bottom
    // nav is genuinely tight.
    final state = await _studentState();
    addTearDown(state.dispose);
    await _setViewport(tester, _viewports.first);
    await tester.pumpWidget(_studentApp(state));
    await tester.tap(find.byKey(const Key('student-assistant-tab')));
    await tester.pumpAndSettle();

    for (final size in _viewports) {
      tester.view.physicalSize = size;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final error = tester.takeException();
      expect(
        error,
        isNull,
        reason: 'Assistant tab overflowed or threw at ${size.width}×${size.height}',
      );
    }
  });
}

Future<AppState> _adminState() async {
  final state = AppState();
  await state.applyBackendProfile(
    const SessionProfile(
      id: 'responsive-admin',
      email: 'admin@csu.edu.ph',
      fullName: 'Responsive Test Administrator',
      role: 'internal_admin',
      campusClaim: null,
      campusId: null,
      unit: 'Office of the Registrar',
      verificationStatus: 'verified',
      onboardingComplete: true,
      accountStatus: 'active',
      createdAt: null,
    ),
  );
  state.goTo(AppView.facilities);
  return state;
}

Widget _adminApp(AppState state) => AppScope(
  state: state,
  child: MaterialApp(
    builder: (context, child) =>
        AppToastHost(child: child ?? const SizedBox.shrink()),
    home: const AppShell(),
  ),
);

Future<AppState> _studentState() async {
  final state = AppState();
  await state.applyBackendProfile(
    const SessionProfile(
      id: 'responsive-student',
      email: 'student@csu.edu.ph',
      fullName: 'Responsive Test Student',
      role: 'user',
      campusClaim: 'student',
      campusId: '2026-00999',
      unit: 'BS Information Technology',
      verificationStatus: 'verified',
      onboardingComplete: true,
      accountStatus: 'active',
      createdAt: null,
    ),
  );
  return state;
}

Widget _studentApp(AppState state) => AppScope(
  state: state,
  child: MaterialApp(
    builder: (context, child) =>
        AppToastHost(child: child ?? const SizedBox.shrink()),
    home: const Scaffold(body: StudentApp()),
  ),
);

Future<void> _setViewport(
  WidgetTester tester,
  Size size, {
  bool registerTearDown = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  if (registerTearDown) {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
}
