import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../data/campus_data.dart';
import '../../../theme/sr_tokens.dart';
import '../../../util/geo.dart';
import '../../../widgets/sr_controls.dart';
import '../add_facility_controller.dart';
import 'campus_map.dart';

class MobilePinSheet extends StatefulWidget {
  const MobilePinSheet({super.key, required this.controller});

  final AddFacilityController controller;

  static Future<void> open(
    BuildContext context,
    AddFacilityController controller,
  ) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => MobilePinSheet(controller: controller),
    ),
  );

  @override
  State<MobilePinSheet> createState() => _MobilePinSheetState();
}

class _MobilePinSheetState extends State<MobilePinSheet> {
  final _map = MapController();
  late LatLng _center =
      widget.controller.draft.pin ??
      buildingNamed(widget.controller.draft.building)?.coords ??
      campus.center;
  late double _zoom = widget.controller.draft.pin == null ? 17.0 : 19.0;

  bool get _inside => inPolygon(_center, campus.boundary);

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      backgroundColor: SR.bg,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
              decoration: const BoxDecoration(
                color: SR.bg,
                border: Border(bottom: BorderSide(color: SR.border)),
              ),
              child: Row(
                children: [
                  SrIconButton(
                    glyph: '←',
                    tooltip: 'Back to the form',
                    size: 40,
                    fontSize: 15,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pin the exact location',
                          style: sans(14, w: 600, tracking: -.01),
                        ),
                        Text(
                          'Drag the map so the crosshair sits on the doorway.',
                          style: sans(11, color: SR.ink4),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: FlutterMap(
                      mapController: _map,
                      options: MapOptions(
                        initialCenter: _center,
                        initialZoom: _zoom,
                        minZoom: 3,
                        maxZoom: 21,
                        backgroundColor: SR.mapBg,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                        ),
                        onPositionChanged: (camera, _) => setState(() {
                          _center = camera.center;
                          _zoom = camera.zoom;
                        }),
                      ),
                      children: [
                        srTileLayer(c.layer, c.tileGeneration),
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
                        Align(
                          alignment: Alignment.bottomLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            color: const Color(0xB8FFFFFF),
                            child: Text(
                              attributionFor(c.layer),
                              style: sans(9, color: SR.ink3),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Center(child: _Crosshair()),
                  Positioned(
                    right: 12,
                    top: 12,
                    child: Column(
                      children: [
                        SrIconButton(
                          glyph: '＋',
                          tooltip: 'Zoom in',
                          size: 44,
                          fontSize: 16,
                          shadow: SR.floatShadow,
                          onPressed: () =>
                              _map.move(_center, (_zoom + 1).clamp(3, 21)),
                        ),
                        const SizedBox(height: 8),
                        SrIconButton(
                          glyph: '－',
                          tooltip: 'Zoom out',
                          size: 44,
                          fontSize: 16,
                          shadow: SR.floatShadow,
                          onPressed: () =>
                              _map.move(_center, (_zoom - 1).clamp(3, 21)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _ConfirmBar(
              coords: formatCoords(_center),
              inside: _inside,
              accuracy: accuracyForZoom(_zoom),
              onGps: () async {
                await c.useGps();
                final pin = c.draft.pin;
                if (pin != null && mounted) {
                  _map.move(pin, 19);
                  if (context.mounted) Navigator.of(context).pop();
                }
              },
              onConfirm: () {
                c.syncZoom(_zoom);
                if (c.draft.pin == null) {
                  c.dropPin(_center, announce: false);
                } else {
                  c.movePin(_center);
                }
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Crosshair extends StatelessWidget {
  const _Crosshair();

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: SR.blue.withValues(alpha: .5),
                width: 2,
              ),
              color: SR.blue.withValues(alpha: .08),
            ),
          ),
          Container(width: 2, height: 56, color: SR.blue.withValues(alpha: .5)),
          Container(width: 56, height: 2, color: SR.blue.withValues(alpha: .5)),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: SR.blue,
              shape: BoxShape.circle,
              border: Border.all(color: SR.surface, width: 2),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ConfirmBar extends StatelessWidget {
  const _ConfirmBar({
    required this.coords,
    required this.inside,
    required this.accuracy,
    required this.onConfirm,
    required this.onGps,
  });

  final String coords;
  final bool inside;
  final int accuracy;
  final VoidCallback onConfirm;
  final VoidCallback onGps;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
    decoration: const BoxDecoration(
      color: SR.surface,
      border: Border(top: BorderSide(color: SR.border)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('CROSSHAIR', style: keyLabel),
                  const SizedBox(height: 3),
                  Text(coords, style: mono(13, w: 500)),
                ],
              ),
            ),
            SrPill(
              label: inside ? 'INSIDE CAMPUS' : 'OUTSIDE',
              background: inside ? SR.greenTint : SR.redTint,
              foreground: inside ? SR.greenDark : SR.red,
              monospace: true,
              fontSize: 9.5,
            ),
          ],
        ),
        const SizedBox(height: 12),

        SrButton(
          label: "Use my location (I'm standing in the room)",
          kind: SrButtonKind.primary,
          expand: true,
          minHeight: 46,
          fontSize: 13,
          onPressed: onGps,
        ),
        const SizedBox(height: 8),
        SrButton(
          label: 'Use this spot · ±$accuracy m',
          expand: true,
          minHeight: 46,
          fontSize: 13,
          onPressed: onConfirm,
        ),
      ],
    ),
  );
}
