import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/widgets/signature_pad.dart';

void main() {
  group('SignaturePadController', () {
    test('starts empty with not enough ink', () {
      final controller = SignaturePadController();
      expect(controller.isEmpty, isTrue);
      expect(controller.hasEnoughInk, isFalse);
    });

    test('a drag produces a non-empty stroke', () {
      final controller = SignaturePadController()
        ..beginStroke(const Offset(0.1, 0.5))
        ..extendStroke(const Offset(0.5, 0.2))
        ..extendStroke(const Offset(0.9, 0.6))
        ..endStroke();
      expect(controller.isEmpty, isFalse);
      expect(controller.strokes, hasLength(1));
      expect(controller.strokes.single, hasLength(3));
    });

    test('a single tap is not enough ink to submit', () {
      final controller = SignaturePadController()
        ..beginStroke(const Offset(0.4, 0.4))
        ..endStroke();
      expect(controller.isEmpty, isFalse);
      expect(controller.hasEnoughInk, isFalse);
    });

    test('a long drag is enough ink to submit', () {
      final controller = SignaturePadController()..beginStroke(Offset.zero);
      for (var i = 1; i <= 20; i++) {
        controller.extendStroke(Offset(i / 20, 0));
      }
      controller.endStroke();
      expect(controller.hasEnoughInk, isTrue);
    });

    test('undo drops only the last stroke', () {
      final controller = SignaturePadController()
        ..beginStroke(const Offset(0.1, 0.1))
        ..extendStroke(const Offset(0.2, 0.2))
        ..endStroke()
        ..beginStroke(const Offset(0.3, 0.3))
        ..extendStroke(const Offset(0.4, 0.4))
        ..endStroke();
      expect(controller.strokes, hasLength(2));
      controller.undo();
      expect(controller.strokes, hasLength(1));
      expect(controller.strokes.single.first, const Offset(0.1, 0.1));
    });

    test('clear empties every stroke', () {
      final controller = SignaturePadController()
        ..beginStroke(const Offset(0.1, 0.1))
        ..extendStroke(const Offset(0.2, 0.2))
        ..endStroke();
      controller.clear();
      expect(controller.isEmpty, isTrue);
    });

    test('points outside 0..1 are clamped', () {
      final controller = SignaturePadController()
        ..beginStroke(const Offset(-0.5, 2.0))
        ..endStroke();
      expect(controller.strokes.single.single, const Offset(0.0, 1.0));
    });
  });

  group('renderSignaturePng', () {
    testWidgets('renders an opaque PNG under the 5 MB ceiling', (
      tester,
    ) async {
      final controller = SignaturePadController()
        ..beginStroke(const Offset(0.1, 0.5))
        ..extendStroke(const Offset(0.5, 0.2))
        ..extendStroke(const Offset(0.9, 0.6))
        ..endStroke();

      // toImage/toByteData round-trip through the real engine and never
      // complete under the fake test clock without runAsync.
      final bytes = await tester.runAsync(
        () => renderSignaturePng(controller.strokes),
      );

      expect(bytes, isNotNull);
      expect(bytes, isNotEmpty);
      expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]); // PNG magic
      expect(bytes.lengthInBytes, lessThan(5 * 1024 * 1024));
    });
  });

  group('SignaturePad', () {
    testWidgets('draws while nested inside a scroll view instead of scrolling', (
      tester,
    ) async {
      final controller = SignaturePadController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  // Kept near the top so it is on screen at the initial scroll
                  // offset; the large trailing box is what makes the ancestor
                  // Scrollable actually able to scroll.
                  const SizedBox(height: 20),
                  SizedBox(
                    width: 300,
                    child: SignaturePad(controller: controller),
                  ),
                  const SizedBox(height: 2000),
                ],
              ),
            ),
          ),
        ),
      );

      final padSize = tester.getSize(find.byType(SignaturePad));
      await tester.dragFrom(
        tester.getTopLeft(find.byType(SignaturePad)) +
            Offset(padSize.width * 0.1, padSize.height * 0.1),
        Offset(padSize.width * 0.5, padSize.height * 0.3),
      );
      await tester.pump();

      expect(controller.isEmpty, isFalse);
    });

    testWidgets('does not draw when disabled', (tester) async {
      final controller = SignaturePadController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SignaturePad(controller: controller, enabled: false),
          ),
        ),
      );

      await tester.dragFrom(
        tester.getCenter(find.byType(SignaturePad)),
        const Offset(60, 20),
      );
      await tester.pump();

      expect(controller.isEmpty, isTrue);
    });
  });
}
