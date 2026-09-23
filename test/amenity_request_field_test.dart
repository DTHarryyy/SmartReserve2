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
  Set<String>? selectedIncluded,
}) async {
  final selectedValues = selected ?? <String>{};
  final selectedIncludedValues = selectedIncluded ?? includedAmenities.toSet();
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
            selectedIncludedAmenities: selectedIncludedValues,
            requestableAmenities: requestableAmenities,
            selectedRequestedAmenities: selectedValues,
            onToggleIncluded: (label) => setState(() {
              if (!selectedIncludedValues.remove(label)) {
                selectedIncludedValues.add(label);
              }
            }),
            onRemoveIncluded: (label) =>
                setState(() => selectedIncludedValues.remove(label)),
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

  testWidgets('included standard amenities are separate from additional ones', (
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
    expect(
      find.byKey(const ValueKey('included-amenity-row-Wi-Fi')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('included-amenity-row-Projector')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('amenity-row-Wi-Fi')), findsNothing);
    expect(find.byKey(const ValueKey('amenity-row-Smart TV')), findsOneWidget);
  });

  testWidgets('included amenities can be removed and selected again', (
    tester,
  ) async {
    await _pumpField(
      tester,
      includedAmenities: const ['Wi-Fi', 'Projector'],
      requestableAmenities: const ['Smart TV'],
    );

    await tester.tap(find.bySemanticsLabel('Remove included Wi-Fi'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('included-amenity-chip-Wi-Fi')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('included-amenity-chip-Projector')),
      findsOneWidget,
    );

    await _openPicker(tester);
    await tester.tap(find.byKey(const ValueKey('included-amenity-row-Wi-Fi')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('included-amenity-chip-Wi-Fi')),
      findsOneWidget,
    );
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
    for (final label in ['Generator', 'Projector', 'Smart TV']) {
      final row = find.byKey(ValueKey('amenity-row-$label'));
      await tester.ensureVisible(row);
      await tester.tap(row);
    }
    await tester.tapAt(const Offset(700, 100));
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

  testWidgets('all-included facilities remain selectable in the picker', (
    tester,
  ) async {
    await _pumpField(
      tester,
      includedAmenities: standardAmenityLabels,
      requestableAmenities: const [],
    );

    await _openPicker(tester);

    for (final label in standardAmenityLabels) {
      expect(
        find.byKey(ValueKey('included-amenity-row-$label')),
        findsOneWidget,
      );
    }
  });
}
