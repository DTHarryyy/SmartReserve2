import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/notice.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/widgets/notices.dart';

void main() {
  Future<void> pumpToast(WidgetTester tester, ThemeData theme) =>
      tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SrToast(
              message: const ToastMessage.error(
                'Representative was not created.',
              ),
              onDismiss: () {},
              onAction: () {},
            ),
          ),
        ),
      );

  testWidgets('error toast message explicitly has no text decoration', (
    tester,
  ) async {
    await pumpToast(tester, SrThemeData.light());
    var message = tester.widget<Text>(
      find.text('Representative was not created.'),
    );
    expect(message.style?.decoration, TextDecoration.none);
    expect(message.style?.decorationColor, Colors.transparent);

    await pumpToast(tester, SrThemeData.dark());
    message = tester.widget<Text>(find.text('Representative was not created.'));
    expect(message.style?.decoration, TextDecoration.none);
    expect(message.style?.decorationColor, Colors.transparent);
  });
}
