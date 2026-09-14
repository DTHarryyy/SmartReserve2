import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartreserve/app/app_shell.dart';
import 'package:smartreserve/app/sr_toast_controller.dart';
import 'package:smartreserve/data/seed_facilities.dart';
import 'package:smartreserve/features/add_facility/add_facility_controller.dart';
import 'package:smartreserve/features/add_facility/add_facility_screen.dart';
import 'package:smartreserve/features/add_facility/widgets/campus_map.dart';
import 'package:smartreserve/theme/sr_theme.dart';

void main() {
  late SrToastController toasts;
  late AddFacilityController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    toasts = SrToastController();
    controller = AddFacilityController(toastController: toasts);
  });

  tearDown(() {
    controller.dispose();
    toasts.dispose();
  });

  // Drains the geocode debounce (650ms) and the autosave timer (1.5s) so the
  // harness doesn't fail teardown on a pending timer.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 2));
    }
  }

  Future<void> pumpEditor(WidgetTester tester, {Layout layout = Layout.desktop}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: SrThemeData.light(),
        home: SrThemeBridge(
          child: Scaffold(
            body: AddFacilityBody(
              controller: controller,
              layout: layout,
              onSave: () {},
              onBackToList: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await settle(tester);
  }

  testWidgets('opens for a new record without throwing', (tester) async {
    controller.startNewRecord();
    await pumpEditor(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(CampusMap), findsOneWidget);
  });

  testWidgets('opens for editing a facility that has a pin', (tester) async {
    final facility = seedFacilities().firstWhere((f) => f.coords != null);
    controller.availableFacilities = seedFacilities();
    controller.loadForEditing(facility);
    await pumpEditor(tester);

    expect(tester.takeException(), isNull);
    expect(controller.draft.pin, isNotNull);
  });

  testWidgets('opens for editing a facility without a pin', (tester) async {
    final facility = seedFacilities().firstWhere((f) => f.coords == null);
    controller.availableFacilities = seedFacilities();
    controller.loadForEditing(facility);
    await pumpEditor(tester);

    expect(tester.takeException(), isNull);
  });

  testWidgets('zoom controls do not throw right after open', (tester) async {
    controller.startNewRecord();
    await pumpEditor(tester);

    controller.map.zoomBy(1);
    await tester.pump();
    controller.map.zoomBy(-1);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('survives edit then add on the same controller', (tester) async {
    final facility = seedFacilities().firstWhere((f) => f.coords != null);
    controller.availableFacilities = seedFacilities();
    controller.loadForEditing(facility);
    await pumpEditor(tester);
    expect(tester.takeException(), isNull);

    controller.startNewRecord();
    await tester.pump();
    await settle(tester);

    expect(tester.takeException(), isNull);
  });
}
