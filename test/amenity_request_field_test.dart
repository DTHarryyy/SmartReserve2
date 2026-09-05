import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/data/campus_data.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/widgets/amenity_request_field.dart';

Future<void> _pumpField(
  WidgetTester tester, {
  required List<String> includedAmenities,
  required List<String> requestableAmenities,
  Set<String>? selected,
}) async {
  final selectedValues = selected ?? <String>{};
  await tester.pumpWidget(
    MaterialApp(
      theme: SrThemeData.light(),
      debugShowCheckedModeBanner: false,
      builder: (context, child) =>
          SrThemeBridge(child: child ?? const SizedBox.shrink()),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => AmenityRequestField(
            includedAmenities: includedAmenities,
            requestableAmenities: requestableAmenities,
            selectedRequestedAmenities: selectedValues,
            onToggle: (label) => setState(() {
              if (!selectedValues.remove(label)) selectedValues.add(label);
            }),
            onRemove: (label) => setState(() => selectedValues.remove(label)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('amenity-request-trigger')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'facility with no included amenities can request all catalog items',
    (tester) async {
      await _pumpField(
        tester,
        includedAmenities: const [],
        requestableAmenities: standardAmenityLabels,
      );

      await _openPicker(tester);

      for (final label in standardAmenityLabels) {
        expect(find.byKey(ValueKey('amenity-row-$label')), findsOneWidget);
      }
    },
  );

  testWidgets('included standard amenities are not requestable', (
    tester,
  ) async {
    await _pumpField(
      tester,
      includedAmenities: const ['Wi-Fi', 'Projector'],
      requestableAmenities: [
        for (final label in standardAmenityLabels)
          if (label != 'Wi-Fi' && label != 'Projector') label,
      ],
    );

    await _openPicker(tester);

    expect(
      find.byKey(const ValueKey('included-amenity-chip-Wi-Fi')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('included-amenity-chip-Projector')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('amenity-row-Wi-Fi')), findsNothing);
    expect(find.byKey(const ValueKey('amenity-row-Projector')), findsNothing);
    expect(find.byKey(const ValueKey('amenity-row-Smart TV')), findsOneWidget);
  });

  testWidgets('multi-select toggles and chips follow catalog order', (
    tester,
  ) async {
    await _pumpField(
      tester,
      includedAmenities: const [],
      requestableAmenities: standardAmenityLabels,
    );

    await _openPicker(tester);
    await tester.tap(find.byKey(const ValueKey('amenity-row-Generator')));
    await tester.tap(find.byKey(const ValueKey('amenity-row-Projector')));
    await tester.tap(find.byKey(const ValueKey('amenity-row-Smart TV')));
    await tester.pumpAndSettle();

    final chips = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('amenity-field-wrap')),
            matching: find.byType(Text),
          ),
        )
        .map((text) => text.data)
        .whereType<String>()
        .where(
          (value) => ['Projector', 'Smart TV', 'Generator'].contains(value),
        )
        .toList();
    expect(chips, ['Projector', 'Smart TV', 'Generator']);

    await tester.tap(find.bySemanticsLabel('Remove Smart TV'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('amenity-chip-Smart TV')), findsNothing);
    expect(
      find.byKey(const ValueKey('amenity-chip-Projector')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('amenity-chip-Generator')),
      findsOneWidget,
    );
  });

  testWidgets('custom included tags do not become requestable options', (
    tester,
  ) async {
    await _pumpField(
      tester,
      includedAmenities: const ['Podium'],
      requestableAmenities: standardAmenityLabels,
    );

    expect(
      find.byKey(const ValueKey('included-amenity-chip-Podium')),
      findsOneWidget,
    );

    await _openPicker(tester);

    expect(find.byKey(const ValueKey('amenity-row-Podium')), findsNothing);
    expect(find.byKey(const ValueKey('amenity-row-Wi-Fi')), findsOneWidget);
  });

  testWidgets('all-included facilities show an explicit empty state', (
    tester,
  ) async {
    await _pumpField(
      tester,
      includedAmenities: standardAmenityLabels,
      requestableAmenities: const [],
    );

    await _openPicker(tester);

    expect(
      find.text('All standard amenities are included with this facility.'),
      findsOneWidget,
    );
  });
}
