import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../../data/campus_data.dart';
import '../../theme/sr_tokens.dart';
import '../../util/geo.dart';
import '../../widgets/sr_controls.dart';
import 'add_facility_controller.dart';
import 'widgets/advisory_card.dart';
import 'widgets/campus_map.dart';
import 'widgets/map_search.dart';
import 'widgets/student_preview.dart';

import '../../theme/sr_theme.dart';

class MapPane extends StatelessWidget {
  const MapPane({
    super.key,
    required this.controller,
    required this.padding,
    this.compact = false,
    this.strip = false,
    this.showHeader = true,
    this.showFooter = true,
  });

  final AddFacilityController controller;
  final EdgeInsets padding;

  final bool compact;

  final bool strip;
  final bool showHeader;
  final bool showFooter;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader) ...[
          AnimatedBuilder(
            animation: Listenable.merge([controller.map, controller.form]),
            builder: (context, _) => _Header(controller: controller),
          ),
          const SizedBox(height: 12),
        ],

        if (strip)
          SizedBox(
            height: 260,
            child: _MapSurface(
              controller: controller,
              compact: compact,
              strip: strip,
            ),
          )
        else
          Expanded(
            child: _MapSurface(
              controller: controller,
              compact: compact,
              strip: strip,
            ),
          ),
        AnimatedBuilder(
          animation: Listenable.merge([controller.map, controller.form]),
          builder: (context, _) => switch (controller.map.advisory) {
            final advisory? => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                AdvisoryCard(advisory: advisory),
              ],
            ),
            null => const SizedBox.shrink(),
          },
        ),
        if (showFooter) ...[
          const SizedBox(height: 12),
          AnimatedBuilder(
            animation: controller.map,
            builder: (context, _) => _Footer(controller: controller.map),
          ),
        ],
      ],
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final AddFacilityController controller;

  @override
  Widget build(BuildContext context) {
    final (badge, badgeBg, badgeFg) = controller.map.pinBadge(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      'Pin the exact location',
                      style: sans(13.5, w: 600, tracking: -.01),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SrPill(
                    label: badge,
                    background: badgeBg,
                    foreground: badgeFg,
                    monospace: true,
                    fontSize: 9.5,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                controller.map.mapHint,
                style: sans(11, color: context.srColors.ink4),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        _TabSwitch(controller: controller.map),
      ],
    );
  }
}

class _TabSwitch extends StatelessWidget {
  const _TabSwitch({required this.controller});

  final MapEditorController controller;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: context.srColors.hairline,
      borderRadius: BorderRadius.circular(9),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final tab in MapTab.values)
          _Tab(
            label: tab == MapTab.map ? 'Map' : 'Preview',
            selected: controller.tab == tab,
            onTap: () => controller.setTab(tab),
          ),
      ],
    ),
  );
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SR.stateChange,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? context.srColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            boxShadow: selected ? SR.cardShadow : null,
          ),
          child: Text(
            label,
            style: sans(
              11.5,
              w: 500,
              color: selected
                  ? context.srColors.ink
                  : (hovered ? context.srColors.ink2 : context.srColors.ink4),
            ),
          ),
        ),
      ),
    ),
  );
}

class _MapSurface extends StatelessWidget {
  const _MapSurface({
    required this.controller,
    required this.compact,
    required this.strip,
  });

  final AddFacilityController controller;
  final bool compact;
  final bool strip;

  double get _control => compact ? 40 : 32;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller.map,
    builder: (context, _) {
      final map = controller.map;
      return ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Container(
          decoration: BoxDecoration(
            color: context.srColors.mapBg,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: context.srColors.borderField),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned.fill(child: CampusMap(controller: map)),

              if (!map.hasPin && !map.mapOffline)
                const Center(child: _DropHint()),

              Positioned(
                left: 12,
                right: 12,
                top: 12,
                child: MapSearchBar(controller: map, compact: compact),
              ),

              Positioned(
                right: 12,
                bottom: strip ? 12 : 64,
                child: _MapTools(
                  controller: map,
                  size: _control,
                  horizontal: strip,
                ),
              ),

              if (map.hasPin)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _PinReadout(
                    controller: map,
                    compact: compact,
                    strip: strip,
                  ),
                ),

              if (map.mapOffline)
                Positioned.fill(child: _OfflinePanel(controller: map)),

              if (map.tab == MapTab.preview)
                Positioned.fill(child: StudentPreview(controller: controller)),
            ],
          ),
        ),
      );
    },
  );
}

class _DropHint extends StatelessWidget {
  const _DropHint();

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: context.srColors.glass,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.srColors.glassLine),
        boxShadow: SR.popoverShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Click to drop the pin', style: sans(13, w: 600)),
          const SizedBox(height: 3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 230),
            child: Text(
              'Then drag or nudge it until it sits on the actual doorway.',
              textAlign: TextAlign.center,
              style: sans(11, height: 1.5, color: context.srColors.ink4),
            ),
          ),
        ],
      ),
    ),
  );
}

class _MapTools extends StatelessWidget {
  const _MapTools({
    required this.controller,
    required this.size,
    required this.horizontal,
  });

  final MapEditorController controller;
  final double size;

  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final axis = horizontal ? Axis.horizontal : Axis.vertical;

    final zoomPair = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: context.srColors.glass,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.srColors.glassLine),
        boxShadow: SR.floatShadow,
      ),
      child: Flex(
        direction: axis,
        mainAxisSize: MainAxisSize.min,
        children: [
          SrIconButton(
            glyph: '＋',
            tooltip: 'Zoom in',
            size: size,
            fontSize: 14,
            radius: 0,
            border: null,
            background: Colors.transparent,
            onPressed: () => controller.zoomBy(1),
          ),
          Container(
            width: horizontal ? 1 : size,
            height: horizontal ? size : 1,
            color: context.srColors.divider,
          ),
          SrIconButton(
            glyph: '－',
            tooltip: 'Zoom out',
            size: size,
            fontSize: 14,
            radius: 0,
            border: null,
            background: Colors.transparent,
            onPressed: () => controller.zoomBy(-1),
          ),
        ],
      ),
    );

    final controls = <Widget>[
      zoomPair,
      for (final tool in _tools(controller))
        SrIconButton(
          glyph: tool.glyph,
          tooltip: tool.tooltip,
          size: size,
          background: tool.active
              ? context.srColors.primaryTint
              : context.srColors.glass,
          foreground: tool.active ? SR.primary : context.srColors.ink2,
          border: context.srColors.glassLine,
          shadow: SR.floatShadow,
          onPressed: tool.onPressed,
        ),
    ];

    return Flex(
      direction: axis,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < controls.length; i++) ...[
          if (i > 0) const SizedBox(width: 7, height: 7),
          controls[i],
        ],
      ],
    );
  }

  static List<
    ({String glyph, String tooltip, bool active, VoidCallback onPressed})
  >
  _tools(MapEditorController c) => [
    (
      glyph: '⌖',
      tooltip: 'Fit the campus',
      active: false,
      onPressed: () => c.centerOn(campus.center, zoom: 17),
    ),
    (
      glyph: '⬡',
      tooltip: c.showBoundary
          ? 'Hide the campus boundary'
          : 'Show the campus boundary',
      active: c.showBoundary,
      onPressed: c.toggleBoundary,
    ),
    (
      glyph: '⌂',
      tooltip: c.showExistingPins
          ? 'Hide facilities already mapped'
          : 'Show facilities already mapped',
      active: c.showExistingPins,
      onPressed: c.toggleExistingPins,
    ),
    (
      glyph: c.fullscreenMap ? '⤡' : '⛶',
      tooltip: c.fullscreenMap ? 'Exit full screen' : 'Full-screen map',
      active: c.fullscreenMap,
      onPressed: () => c.setFullscreenMap(!c.fullscreenMap),
    ),
  ];
}

class _PinReadout extends StatelessWidget {
  const _PinReadout({
    required this.controller,
    required this.compact,
    required this.strip,
  });

  final MapEditorController controller;
  final bool compact;
  final bool strip;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.end,
    children: [
      _FloatingCard(
        child: Semantics(
          button: true,
          label: 'Copy the pinned coordinates',
          child: Hoverable(
            builder: (context, hovered) => GestureDetector(
              onTap: () async {
                await Clipboard.setData(
                  ClipboardData(text: controller.coordLabel),
                );
                controller.showToast(
                  const ToastMessage('Coordinates copied to the clipboard.'),
                );
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    hovered ? 'COPY COORDINATES' : 'PINNED COORDINATES',
                    style: keyLabel,
                  ),
                  const SizedBox(height: 3),
                  Text(controller.coordLabel, style: mono(12, w: 500)),
                ],
              ),
            ),
          ),
        ),
      ),

      if (!strip) ...[
        _FloatingCard(
          padding: const EdgeInsets.all(7),
          child: _NudgePad(controller: controller, compact: compact),
        ),
        SrButton(
          label: 'Remove pin',
          kind: SrButtonKind.danger,
          dense: true,
          fontSize: 11.5,
          onPressed: controller.clearPin,
        ),
      ],
    ],
  );
}

class _FloatingCard extends StatelessWidget {
  const _FloatingCard({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: context.srColors.glass,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: context.srColors.glassLine),
      boxShadow: SR.floatShadow,
    ),
    child: child,
  );
}

class _NudgePad extends StatelessWidget {
  const _NudgePad({required this.controller, required this.compact});

  final MapEditorController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final w = compact ? 30.0 : 22.0;
    final h = compact ? 26.0 : 18.0;

    Widget key(String glyph, String label, {double n = 0, double e = 0}) =>
        SrIconButton(
          glyph: glyph,
          tooltip: label,
          size: w,
          fontSize: 8,
          radius: 5,
          border: context.srColors.hairline,
          foreground: context.srColors.ink3,
          onPressed: () => controller.nudgePin(north: n, east: e),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'NUDGE 1 m',
          style: mono(
            8.5,
            w: 500,
            tracking: .04,
            color: context.srColors.muted,
          ),
        ),
        const SizedBox(height: 3),
        SizedBox(height: h, child: key('▲', 'Nudge north', n: 1)),
        const SizedBox(height: 2),
        SizedBox(
          height: h,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              key('◀', 'Nudge west', e: -1),
              const SizedBox(width: 2),
              key('▼', 'Nudge south', n: -1),
              const SizedBox(width: 2),
              key('▶', 'Nudge east', e: 1),
            ],
          ),
        ),
      ],
    );
  }
}

class _OfflinePanel extends StatelessWidget {
  const _OfflinePanel({required this.controller});

  final MapEditorController controller;

  @override
  Widget build(BuildContext context) => Container(
    color: context.srColors.bg,
    alignment: Alignment.center,
    padding: const EdgeInsets.all(24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.srColors.surface,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: context.srColors.border),
            ),
            child: Icon(
              Icons.wifi_off_rounded,
              size: 18,
              color: context.srColors.red,
            ),
          ),
          const SizedBox(height: 14),
          Text('Map tiles are not loading', style: sans(13.5, w: 600)),
          const SizedBox(height: 5),
          Text(
            'The connection to the tile server failed. You can still enter '
            'coordinates manually and verify the pin later.',
            textAlign: TextAlign.center,
            style: sans(11.5, height: 1.6, color: context.srColors.ink4),
          ),
          const SizedBox(height: 14),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 7,
            runSpacing: 7,
            children: [
              SrButton(
                label: 'Retry',
                kind: SrButtonKind.primary,
                dense: true,
                fontSize: 11.5,
                onPressed: controller.retryMap,
              ),
              SrButton(
                label: 'Enter coordinates',
                dense: true,
                fontSize: 11.5,
                onPressed: controller.openSearch,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Footer extends StatelessWidget {
  const _Footer({required this.controller});

  final MapEditorController controller;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    decoration: BoxDecoration(
      color: context.srColors.surface,
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: context.srColors.border),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            controller.footerHint,
            style: sans(11, height: 1.5, color: context.srColors.ink4),
          ),
        ),
        const SizedBox(width: 10),
        SrButton(
          label: "I'm standing in the room",
          icon: Text('◎', style: sans(12, color: context.srColors.ink2)),
          dense: true,
          fontSize: 11.5,
          onPressed: controller.useGps,
        ),
      ],
    ),
  );
}

LatLng defaultMapCenter(MapEditorController controller) =>
    controller.draft.pin ??
    buildingNamed(controller.draft.building)?.coords ??
    campus.center;

String crosshairLabel(LatLng at) => formatCoords(at);
