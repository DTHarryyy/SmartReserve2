import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/sr_toast_controller.dart';
import 'package:smartreserve/model/notice.dart';

void main() {
  group('SrToastController', () {
    testWidgets('uses tone and action defaults for visibility', (tester) async {
      final controller = SrToastController();
      addTearDown(controller.dispose);

      controller.show(const ToastMessage.success('Saved.'));
      await tester.pump(const Duration(seconds: 3));
      expect(controller.active, isNotNull);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.active, isNull);

      controller.show(const ToastMessage.error('Could not save.'));
      await tester.pump(const Duration(seconds: 5));
      expect(controller.active, isNotNull);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.active, isNull);

      controller.show(
        ToastMessage.success(
          'Archived.',
          action: ToastAction(label: 'Undo', onPressed: () {}),
        ),
      );
      await tester.pump(const Duration(seconds: 7));
      expect(controller.active, isNotNull);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.active, isNull);
    });

    testWidgets('newer and repeated messages replace the active toast', (
      tester,
    ) async {
      final controller = SrToastController();
      addTearDown(controller.dispose);

      controller.show(const ToastMessage.success('Saved.'));
      final firstId = controller.active!.id;
      await tester.pump(const Duration(seconds: 3));
      controller.show(const ToastMessage.success('Saved.'));

      expect(controller.active!.id, greaterThan(firstId));
      await tester.pump(const Duration(seconds: 1));
      expect(controller.active, isNotNull);
      await tester.pump(const Duration(seconds: 3));
      expect(controller.active, isNull);
    });

    testWidgets('dismisses before an action and supports manual dismissal', (
      tester,
    ) async {
      final controller = SrToastController();
      addTearDown(controller.dispose);
      var sawDismissedState = false;

      controller.show(
        ToastMessage.success(
          'Archived.',
          action: ToastAction(
            label: 'Undo',
            onPressed: () => sawDismissedState = controller.active == null,
          ),
        ),
      );
      controller.invokeAction();

      expect(sawDismissedState, isTrue);
      expect(controller.active, isNull);

      controller.show(const ToastMessage.info('Refreshing.'));
      controller.dismiss();
      expect(controller.active, isNull);
    });

    testWidgets('disposing cancels a pending timeout', (tester) async {
      final controller = SrToastController();
      controller.show(const ToastMessage.success('Saved.'));
      controller.dispose();

      await tester.pump(const Duration(seconds: 10));
      expect(controller.active, isNull);
    });
  });
}
