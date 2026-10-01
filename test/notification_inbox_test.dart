import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/widgets/notification_inbox.dart';

Widget _host(AppState state, {ThemeMode mode = ThemeMode.light}) => MaterialApp(
  theme: SrThemeData.light(),
  darkTheme: SrThemeData.dark(),
  themeMode: mode,
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 410,
        height: 560,
        child: AnimatedBuilder(
          animation: state,
          builder: (_, _) => NotificationInbox(state: state),
        ),
      ),
    ),
  ),
);

BackendNotification _notification(int index) => BackendNotification(
  id: 'n$index',
  kind: index == 0 ? 'payment_needs_correction' : 'reservation_reminder',
  title: index == 0 ? 'Payment needs correction' : 'Reservation tomorrow',
  body: index == 0 ? 'Upload a clearer payment proof.' : 'Gymnasium at 9:00 AM',
  requestId: 'r$index',
  createdAt: DateTime.now().subtract(Duration(minutes: index + 1)),
);

void main() {
  testWidgets('shows a professional empty state', (tester) async {
    final state = AppState(useDemoData: false);
    await tester.pumpWidget(_host(state));

    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('You’re all caught up'), findsOneWidget);
    expect(
      find.text('New updates and actions will appear here.'),
      findsOneWidget,
    );
  });

  testWidgets('shows contextual content and actions', (tester) async {
    final state = AppState(useDemoData: false)
      ..notifications = [_notification(0)];
    await tester.pumpWidget(_host(state));

    expect(find.text('Payment needs correction'), findsOneWidget);
    expect(find.text('Upload a clearer payment proof.'), findsOneWidget);
    expect(find.text('Fix payment'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('an opened notification vanishes immediately', (tester) async {
    final state = AppState(useDemoData: false)
      ..notifications = [_notification(0)];
    await tester.pumpWidget(_host(state));

    await tester.tap(find.text('Payment needs correction'));
    await tester.pump();

    expect(state.notifications, isEmpty);
    expect(find.text('You’re all caught up'), findsOneWidget);
  });

  testWidgets('mobile inbox has a close target and drag handle', (
    tester,
  ) async {
    final state = AppState(useDemoData: false);
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: SrThemeData.light(),
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 650,
            child: NotificationInbox(
              state: state,
              mobile: true,
              onClose: () => closed = true,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('notification-drag-handle')), findsOneWidget);
    await tester.tap(find.byTooltip('Close notifications'));
    expect(closed, isTrue);
  });

  testWidgets('caps the unread badge and renders in dark mode', (tester) async {
    final state = AppState(useDemoData: false)
      ..notifications = [for (var i = 0; i < 100; i++) _notification(i)];
    await tester.pumpWidget(_host(state, mode: ThemeMode.dark));

    expect(find.text('99+'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
