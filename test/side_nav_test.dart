import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/app/app_view.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/widgets/side_nav.dart';

Future<void> _pumpSideNav(
  WidgetTester tester, {
  required AppState state,
  required ValueChanged<AppView> onSelect,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: SrThemeData.light(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: SideNav.width,
            child: SideNav(state: state, onSelect: onSelect),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Color _backgroundColor(WidgetTester tester, AppView section) {
  final container = tester.widget<Container>(
    find.byKey(ValueKey('side-nav-item-${section.name}')),
  );
  return (container.decoration! as BoxDecoration).color!;
}

void main() {
  testWidgets('sidebar hover is exclusive and clears immediately', (
    tester,
  ) async {
    final state = AppState()..view = AppView.facilities;
    AppView? selected;
    await _pumpSideNav(
      tester,
      state: state,
      onSelect: (section) {
        selected = section;
      },
    );

    final reservations = find.byKey(
      const ValueKey('side-nav-item-reservations'),
    );
    final calendar = find.byKey(const ValueKey('side-nav-item-calendar'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1000, 700));

    await mouse.moveTo(tester.getCenter(reservations));
    await tester.pump();
    expect(
      _backgroundColor(tester, AppView.reservations),
      SrColors.light.surfaceSubtle,
    );
    expect(_backgroundColor(tester, AppView.calendar), Colors.transparent);

    await mouse.moveTo(tester.getCenter(calendar));
    await tester.pump();
    expect(_backgroundColor(tester, AppView.reservations), Colors.transparent);
    expect(
      _backgroundColor(tester, AppView.calendar),
      SrColors.light.surfaceSubtle,
    );

    await mouse.moveTo(const Offset(1000, 700));
    await tester.pump();
    expect(_backgroundColor(tester, AppView.calendar), Colors.transparent);
    expect(
      _backgroundColor(tester, AppView.facilities),
      SrColors.light.primaryTint,
    );

    await tester.tap(calendar);
    expect(selected, AppView.calendar);
  });
}
