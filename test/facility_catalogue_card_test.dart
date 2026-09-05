import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/theme/sr_tokens.dart';
import 'package:smartreserve/widgets/facility_catalogue_card.dart';
import 'package:smartreserve/widgets/sr_controls.dart';

FacilityCatalogueCardData _cardData({
  List<String> amenities = const [
    'Wi-Fi',
    'Projector',
    'Whiteboard',
    'Parking',
    'Generator',
  ],
}) => FacilityCatalogueCardData(
  id: 'facility-card-test',
  name: 'Basketball Court',
  category: 'Outdoor Area',
  statusLabel: 'Available',
  statusTone: SrTone.success,
  locationLabel: 'College of Information and Computing Sciences',
  description:
      'A student-facing multipurpose court for practices, events, and group '
      'activities.',
  includedAmenities: amenities,
  capacityLabel: '50 seats',
  hoursLabel: '07:00-19:00',
  approvalLabel: 'Required',
  availabilityLabel: 'Approval required',
  availabilityTone: SrTone.warning,
  rateLabel: 'PHP1000 / 2 h',
  coverPhoto: null,
  placeholderHue: 210,
  placeholderIcon: Icons.sports_basketball_rounded,
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(420, 640),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: SrThemeData.light(),
      debugShowCheckedModeBanner: false,
      builder: (context, child) =>
          SrThemeBridge(child: child ?? const SizedBox.shrink()),
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shared card keeps the CTA inside the bottom padding', (
    tester,
  ) async {
    for (final scenario in const [
      (viewport: Size(320, 640), cardHeight: 547.5),
      (viewport: Size(1180, 840), cardHeight: 547.5),
    ]) {
      await _pump(
        tester,
        SizedBox(
          width: 300,
          height: scenario.cardHeight,
          child: FacilityCatalogueCard(
            data: _cardData(),
            reserveEnabled: true,
            onReserve: () {},
            onViewDetails: () {},
          ),
        ),
        size: scenario.viewport,
      );

      final cardBottom = tester
          .getBottomRight(find.byType(FacilityCatalogueCard))
          .dy;
      final ctaBottom = tester
          .getBottomRight(
            find.byKey(
              const ValueKey('facility-card-reserve-facility-card-test'),
            ),
          )
          .dy;

      expect(cardBottom - ctaBottom, greaterThanOrEqualTo(12));
      expect(cardBottom - ctaBottom, lessThanOrEqualTo(20));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('preview mode shows all draft amenities', (tester) async {
    await _pump(
      tester,
      FacilityCatalogueCard(
        data: _cardData(
          amenities: const [
            'Wi-Fi',
            'Projector',
            'Whiteboard',
            'Parking',
            'Generator',
          ],
        ),
        reserveEnabled: true,
        previewMode: true,
        onReserve: () {},
      ),
    );

    expect(find.text('Wi-Fi'), findsOneWidget);
    expect(find.text('Projector'), findsOneWidget);
    expect(find.text('Whiteboard'), findsOneWidget);
    expect(find.text('Parking'), findsOneWidget);
    expect(find.text('Generator'), findsOneWidget);
    expect(find.text('+1'), findsNothing);
  });

  testWidgets('browse mode summarizes included amenities after four chips', (
    tester,
  ) async {
    await _pump(
      tester,
      SizedBox(
        width: 300,
        height: 526,
        child: FacilityCatalogueCard(
          data: _cardData(),
          reserveEnabled: true,
          onReserve: () {},
        ),
      ),
    );

    expect(find.text('Wi-Fi'), findsOneWidget);
    expect(find.text('Parking'), findsOneWidget);
    expect(find.text('Generator'), findsNothing);
    expect(find.text('+1'), findsOneWidget);
  });

  testWidgets('SrButton icons inherit enabled and disabled foreground colors', (
    tester,
  ) async {
    Color? muted;
    await _pump(
      tester,
      Builder(
        builder: (context) {
          muted = context.srColors.muted;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SrButton(
                label: 'Enabled',
                kind: SrButtonKind.primary,
                icon: const Icon(Icons.event_available_rounded),
                onPressed: () {},
              ),
              SrButton(
                label: 'Disabled',
                kind: SrButtonKind.primary,
                icon: const Icon(Icons.event_busy_rounded),
              ),
            ],
          );
        },
      ),
    );

    expect(
      IconTheme.of(tester.element(find.byIcon(Icons.event_available_rounded))),
      isA<IconThemeData>().having((theme) => theme.color, 'color', SR.onDark),
    );
    expect(
      IconTheme.of(tester.element(find.byIcon(Icons.event_busy_rounded))),
      isA<IconThemeData>().having((theme) => theme.color, 'color', muted),
    );
  });
}
