import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/theme/sr_tokens.dart';
import 'package:smartreserve/widgets/sr_controls.dart';

double _contrast(Color first, Color second) {
  final light = first.computeLuminance();
  final dark = second.computeLuminance();
  final high = light > dark ? light : dark;
  final low = light > dark ? dark : light;
  return (high + .05) / (low + .05);
}

void _expectContrast(Color foreground, Color background, double minimum) {
  expect(
    _contrast(foreground, background),
    greaterThanOrEqualTo(minimum),
    reason:
        '${foreground.toARGB32().toRadixString(16)} on '
        '${background.toARGB32().toRadixString(16)}',
  );
}

Future<void> _pumpButton(
  WidgetTester tester,
  ThemeData theme,
  SrButtonKind kind,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SrThemeData.light(),
      darkTheme: SrThemeData.dark(),
      themeMode: theme.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: Scaffold(
        body: Center(
          child: SrButton(label: 'Continue', kind: kind, onPressed: () {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => SR.activate(Brightness.light));

  test('CSU anchor colors and material schemes stay synchronized', () {
    expect(SrColors.light.brand, const Color(0xFF800020));
    expect(SrColors.light.accent, const Color(0xFFFFC857));
    expect(SrColors.light.canvas, const Color(0xFFF3EFF5));
    expect(SrColors.light.navBg, const Color(0xFFFFFFFF));
    expect(SrColors.dark.navBg, SrColors.dark.surface);
    expect(SrColors.dark.heroStart, const Color(0xFF800020));
    expect(SrColors.dark.brand, const Color(0xFFFFC857));

    final lightScheme = SrThemeData.light().colorScheme;
    expect(lightScheme.primary, SrColors.light.brand);
    expect(lightScheme.onPrimary, SrColors.light.onBrand);
    expect(lightScheme.secondary, SrColors.light.accent);
    expect(lightScheme.surface, SrColors.light.surface);

    final darkScheme = SrThemeData.dark().colorScheme;
    expect(darkScheme.primary, SrColors.dark.brand);
    expect(darkScheme.onPrimary, SrColors.dark.onBrand);
    expect(darkScheme.secondary, SrColors.dark.accent);
    expect(darkScheme.surface, SrColors.dark.surface);
  });

  test('legacy token bridge resolves the active light and dark palettes', () {
    SR.activate(Brightness.light);
    expect(SR.primary, SrColors.light.brand);
    expect(SR.primaryHover, SrColors.light.brandHover);
    expect(SR.primaryBright, SrColors.light.accent);
    expect(SrTone.info.solid, SrColors.light.info);

    SR.activate(Brightness.dark);
    expect(SR.primary, SrColors.dark.brand);
    expect(SR.primaryHover, SrColors.dark.brandHover);
    expect(SR.primaryBright, SrColors.dark.accent);
    expect(SrTone.info.solid, SrColors.dark.info);
  });

  test('principal text and control pairs meet WCAG AA contrast', () {
    final light = SrColors.light;
    final dark = SrColors.dark;

    for (final pair in <(Color, Color)>[
      (light.onBrand, light.brand),
      (light.onAccent, light.accent),
      (light.text, light.canvas),
      (light.textMuted, light.surface),
      (light.navForeground, light.navBg),
      (light.navSelectedForeground, light.navSelectedBg),
      (light.success, light.successContainer),
      (light.warning, light.warningContainer),
      (light.error, light.errorContainer),
      (light.info, light.infoContainer),
      (dark.onBrand, dark.brand),
      (dark.text, dark.canvas),
      (dark.textMuted, dark.surface),
      (dark.navForeground, dark.navBg),
      (dark.navSelectedForeground, dark.navSelectedBg),
      (dark.success, dark.successContainer),
      (dark.warning, dark.warningContainer),
      (dark.error, dark.errorContainer),
      (dark.info, dark.infoContainer),
    ]) {
      _expectContrast(pair.$1, pair.$2, 4.5);
    }
  });

  testWidgets('primary and caution buttons use mode-safe foregrounds', (
    tester,
  ) async {
    await _pumpButton(tester, SrThemeData.light(), SrButtonKind.primary);
    var label = tester.widget<Text>(find.text('Continue'));
    expect(label.style?.color, SrColors.light.onBrand);

    await _pumpButton(tester, SrThemeData.dark(), SrButtonKind.primary);
    label = tester.widget<Text>(find.text('Continue'));
    expect(label.style?.color, SrColors.dark.onBrand);

    await _pumpButton(tester, SrThemeData.light(), SrButtonKind.caution);
    label = tester.widget<Text>(find.text('Continue'));
    expect(label.style?.color, SrColors.light.amberTitle);
  });

  test('retired blue brand literals do not return to application UI', () {
    const forbidden = <String>[
      '0xFF1A73E8',
      '0xFF1765CC',
      '0xFF1254AD',
      '0xFF00B4FF',
      '0xFF1479B8',
      '0xFF68AEFA',
      '0xFF43C5FF',
      '0xFF42E8D4',
      '#6367FF',
    ];
    final files = <File>[
      ...Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
      File('pubspec.yaml'),
      File('web/manifest.json'),
    ];

    for (final file in files) {
      final contents = file.readAsStringSync();
      for (final color in forbidden) {
        expect(
          contents.contains(color),
          isFalse,
          reason: '$color remains in ${file.path}',
        );
      }
    }
  });
}
