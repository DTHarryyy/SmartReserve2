import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/features/policies/policy_view.dart';
import 'package:smartreserve/theme/sr_theme.dart';

void main() {
  for (final kind in PolicyKind.values) {
    testWidgets('${kind.name} document opens with its sections', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SrThemeData.light(),
          builder: (context, child) =>
              SrThemeBridge(child: child ?? const SizedBox.shrink()),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPolicyDocument(context, kind),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(kind.title), findsOneWidget);
      expect(
        find
                .textContaining('1. Account Responsibility')
                .evaluate()
                .isNotEmpty ||
            find
                .textContaining('1. Reservation and Authorization')
                .evaluate()
                .isNotEmpty,
        isTrue,
      );
    });
  }
}
