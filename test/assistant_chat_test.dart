import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/features/assistant/assistant_chat_page.dart';
import 'package:smartreserve/features/assistant/assistant_controller.dart';
import 'package:smartreserve/theme/sr_theme.dart';

Future<void> _pumpAssistant(
  WidgetTester tester, {
  required ThemeData theme,
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppScope(
      state: AppState(),
      child: MaterialApp(
        theme: theme,
        debugShowCheckedModeBanner: false,
        builder: (context, child) =>
            SrThemeBridge(child: child ?? const SizedBox.shrink()),
        home: AssistantChatPage(controller: AssistantController()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('assistant chat renders the redesigned compact transcript', (
    tester,
  ) async {
    await _pumpAssistant(
      tester,
      theme: SrThemeData.light(),
      size: const Size(430, 760),
    );

    expect(find.text('SmartReserve AI'), findsOneWidget);
    expect(find.textContaining('Ask about facilities'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Suggestion: What facilities are available?'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Send'), findsOneWidget);

    await tester.tap(find.byTooltip('Chat history and new chat'));
    await tester.pumpAndSettle();
    expect(find.text('Chat history'), findsOneWidget);
    expect(find.text('New chat'), findsOneWidget);
  });

  testWidgets('assistant chat uses the same accessible layout in dark mode', (
    tester,
  ) async {
    await _pumpAssistant(
      tester,
      theme: SrThemeData.dark(),
      size: const Size(1180, 840),
    );

    expect(find.text('Reservation assistant'), findsOneWidget);
    expect(find.bySemanticsLabel('Message the assistant'), findsOneWidget);
  });

  testWidgets('booking flow opens the facility picker automatically', (
    tester,
  ) async {
    await _pumpAssistant(
      tester,
      theme: SrThemeData.light(),
      size: const Size(430, 760),
    );

    await tester.enterText(find.byType(TextField), 'Book a room');
    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pumpAndSettle();

    expect(find.text('Choose a facility'), findsOneWidget);
    expect(find.text('Browse all facilities'), findsOneWidget);
    expect(find.text('Computer Laboratory 1'), findsOneWidget);

    await tester.tap(find.byTooltip('Close picker'));
    await tester.pumpAndSettle();

    expect(find.text('Choose facility'), findsOneWidget);
  });
}
