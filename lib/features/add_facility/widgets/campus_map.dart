import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../../data/campus_data.dart';
import '../../../theme/sr_tokens.dart';
import '../add_facility_controller.dart';

TileLayer srTileLayer(
  MapLayer layer,
  int generation, {
  bool dark = false,
  VoidCallback? onTileError,
}) => TileLayer(
  key: ValueKey('${layer.name}-$generation'),
  urlTemplate: switch (layer) {
    MapLayer.street =>
      dark
          ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
          : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    MapLayer.satellite =>
      'https://server.arcgisonline.com/ArcGIS/rest/services/'
          'World_Imagery/MapServer/tile/{z}/{y}/{x}',
    MapLayer.light =>
      'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
  },
  subdomains: layer == MapLayer.light || (layer == MapLayer.street && dark)
      ? const ['a', 'b', 'c', 'd']
      : const [],
  maxNativeZoom: 19,
  userAgentPackageName: 'ph.edu.csu.smartreserve',
  errorTileCallback: onTileError == null ? null : (_, _, _) => onTileError(),
);

String attributionFor(MapLayer layer) => switch (layer) {
  MapLayer.street => '© OpenStreetMap · © CARTO',
  MapLayer.satellite => 'Imagery © Esri',
  MapLayer.light => '© OpenStreetMap · © CARTO',
};

class CampusMap extends StatefulWidget {
  const CampusMap({super.key, required this.controller});

  final AddFacilityController controller;

  @override
  State<CampusMap> createState() => _CampusMapState();
}

class _CampusMapState extends State<CampusMap> {
  final _map = MapController();

  int _tileErrors = 0;
  int _seenGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_applyCameraRequest);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_applyCameraRequest);
    super.dispose();
  }

  void _applyCameraRequest() {
    final c = widget.controller;
    if (c.pendingCenter == null && c.pendingZoomTo == null) return;
    final target = c.pendingCenter ?? _map.camera.center;
    final zoom = c.pendingZoomTo ?? c.pendingZoom ?? _map.camera.zoom;
    c.consumeCameraRequest();
    if (!mounted) return;
    _map.move(target, zoom);
    c.syncZoom(zoom);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final pin = c.draft.pin;

    if (_seenGeneration != c.tileGeneration) {
      _seenGeneration = c.tileGeneration;
      _tileErrors = 0;
    }

    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter:
            pin ?? buildingNamed(c.draft.building)?.coords ?? campus.center,
        initialZoom: c.zoom,
        minZoom: 3,
        maxZoom: 21,
        backgroundColor: SR.mapBg,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onTap: (_, latLng) {
          if (c.tab != MapTab.map) return;
          c.closeSearch();
          if (pin == null) {
            c.dropPin(latLng);
          } else {
            c.movePin(latLng);
          }
        },
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture) c.syncZoom(camera.zoom);
        },
      ),
      children: [
        srTileLayer(
          c.layer,
          c.tileGeneration,
          dark: Theme.of(context).brightness == Brightness.dark,
          onTileError: () {
            _tileErrors++;

            if (_tileErrors == 6) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) widget.controller.setMapOffline(true);
              });
            }
          },
        ),

        if (c.showBoundary)
          PolygonLayer(
            polygons: [
              Polygon(
                points: campus.boundary,
                color: SR.blue.withValues(alpha: .10),
                borderColor: SR.blue.withValues(alpha: .9),
                borderStrokeWidth: 2.5,
              ),
            ],
          ),

        if (pin != null && c.draft.accuracy != null)
          CircleLayer(
            circles: [
              CircleMarker(
                point: pin,
                radius: c.draft.accuracy!.toDouble(),
                useRadiusInMeter: true,
                color: SR.blue.withValues(alpha: .12),
                borderColor: SR.blue.withValues(alpha: .45),
                borderStrokeWidth: 1,
              ),
            ],
          ),

        if (c.showExistingPins)
          MarkerLayer(
            markers: [
              for (final b in buildings)
                if (b.mapped)
                  Marker(
                    point: b.coords,
                    width: 132,
                    height: 30,
                    alignment: Alignment.topCenter,
                    child: _BuildingChip(
                      name: b.name,
                      selected: b.name == c.draft.building,
                    ),
                  ),
              for (final f in c.availableFacilities)
                if (f.coords != null)
                  Marker(
                    point: f.coords!,
                    width: 14,
                    height: 14,
                    child: const _ExistingDot(),
                  ),
            ],
          ),

        if (pin != null)
          MarkerLayer(
            markers: [
              Marker(
                point: pin,
                width: 40,
                height: 44,
                alignment: Alignment.topCenter,
                child: _DraggablePin(
                  controller: c,
                  dropId: c.pinDropCount,
                  valid: c.insideBoundary || c.draft.confirmedOutside,
                ),
              ),
            ],
          ),

        Scalebar(
          alignment: Alignment.bottomRight,
          padding: const EdgeInsets.only(right: 12, bottom: 24),
          lineColor: SR.muted,
          textStyle: mono(10, w: 500, color: SR.ink2),
        ),

        Align(
          alignment: Alignment.bottomRight,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            color: SR.glass,
            child: Text(
              attributionFor(c.layer),
              style: sans(9, color: SR.ink3),
            ),
          ),
        ),
      ],
    );
  }
}

class _ExistingDot extends StatelessWidget {
  const _ExistingDot();

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: SR.muted,
        shape: BoxShape.circle,
        border: Border.all(color: SR.surface, width: 1.5),
      ),
    ),
  );
}

class _BuildingChip extends StatelessWidget {
  const _BuildingChip({required this.name, required this.selected});

  final String name;
  final bool selected;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: selected ? SR.blue : SR.glass,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: selected ? SR.blueDark : SR.glassLine),
        ),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: sans(9, w: 500, color: selected ? SR.onDark : SR.ink3),
        ),
      ),
    ),
  );
}

class _DraggablePin extends StatefulWidget {
  const _DraggablePin({
    required this.controller,
    required this.dropId,
    required this.valid,
  });

  final AddFacilityController controller;

  final int dropId;
  final bool valid;

  @override
  State<_DraggablePin> createState() => _DraggablePinState();
}

class _DraggablePinState extends State<_DraggablePin>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cue = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  Offset? _dragAt;

  @override
  void didUpdateWidget(_DraggablePin old) {
    super.didUpdateWidget(old);
    if (old.dropId != widget.dropId) _cue.forward(from: 0);
  }

  @override
  void dispose() {
    _cue.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final color = widget.valid ? SR.blue : SR.red;

    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          final pin = widget.controller.draft.pin;
          if (pin != null) _dragAt = camera.latLngToScreenOffset(pin);
        },
        onPanUpdate: (details) {
          if (_dragAt == null) return;
          _dragAt = _dragAt! + details.delta;
          widget.controller.dragPinTo(camera.screenOffsetToLatLng(_dragAt!));
        },
        onPanEnd: (_) {
          _dragAt = null;
          widget.controller.endPinDrag();
        },
        child: AnimatedBuilder(
          animation: _cue,
          builder: (context, child) {
            final t = _cue.value;

            final pop = t < .2 ? .92 + (t / .2) * .08 : 1.0;
            final pulseT = ((t - .1) / .9).clamp(0.0, 1.0);
            return Stack(
              alignment: Alignment.bottomCenter,
              clipBehavior: Clip.none,
              children: [
                if (pulseT > 0 && pulseT < 1)
                  Positioned(
                    bottom: -14,
                    child: Opacity(
                      opacity: (1 - pulseT) * .5,
                      child: Container(
                        width: 26 + pulseT * 34,
                        height: 26 + pulseT * 34,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: .35),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                Transform.scale(scale: pop, child: child),
              ],
            );
          },
          child: Align(
            alignment: Alignment.topCenter,
            child: Transform.rotate(
              angle: -math.pi / 4,
              child: Container(
                width: 26,
                height: 26,
                margin: const EdgeInsets.only(bottom: 4),
                decoration: BoxDecoration(
                  color: color,
                  border: Border.all(color: SR.surface, width: 2.5),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(13),
                    topRight: Radius.circular(13),
                    bottomRight: Radius.circular(13),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x5910141A),
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
