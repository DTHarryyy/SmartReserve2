import 'package:flutter/material.dart';

import '../../../data/campus_data.dart';
import '../../../model/facility_draft.dart';
import '../../../theme/sr_tokens.dart';
import '../../../util/geo.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/sr_controls.dart';
import '../add_facility_controller.dart';

import '../../../theme/sr_theme.dart';

class LocationSection extends StatelessWidget {
  const LocationSection({
    super.key,
    required this.controller,
    required this.stacked,
    required this.dense,
  });

  final AddFacilityController controller;
  final bool stacked;
  final bool dense;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller.form, controller.map, controller]),
    builder: (context, _) {
      final draft = controller.draft;
      final selected = buildingNamed(draft.building);

      return SectionCard(
        anchorKey: controller.sectionKeys[RequiredItem.building],
        number: '02',
        title: 'Where it sits',
        caption: 'Drives the map pin',
        dense: dense,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FieldRow(
              stacked: stacked,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SrLabel('Campus'),
                    SrSelect<String>(
                      value: draft.campusName,
                      items: campuses,
                      semanticLabel: 'Campus',
                      labelOf: (c) => c,
                      onChanged: (v) {
                        if (v != null) controller.form.setCampus(v);
                      },
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SrLabel(
                      'Building',
                      required: true,
                      meta: selected == null
                          ? null
                          : Text(
                              selected.mapped ? 'MAPPED' : 'NOT MAPPED',
                              style: mono(
                                10,
                                tracking: .04,
                                color: selected.mapped
                                    ? context.srColors.greenDark
                                    : context.srColors.amber,
                              ),
                            ),
                    ),
                    SrSelect<String>(
                      value: draft.building.isEmpty ? null : draft.building,
                      items: [for (final b in buildings) b.name],
                      placeholder: 'Choose a building',
                      semanticLabel: 'Building',
                      hasError: controller.errors.containsKey(
                        RequiredItem.building,
                      ),
                      labelOf: (b) => b,
                      subtitleOf: (b) => buildingNamed(b)?.mapped == false
                          ? 'NOT MAPPED'
                          : null,
                      onChanged: (v) {
                        if (v != null) controller.form.setBuilding(v);
                      },
                    ),
                    SrErrorText(controller.errors[RequiredItem.building]),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SrLabel('Floor'),
                    SrSelect<String>(
                      value: draft.floor,
                      items: floors,
                      semanticLabel: 'Floor',
                      labelOf: (f) => f,
                      onChanged: (v) {
                        if (v != null) controller.form.setFloor(v);
                      },
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SrLabel('Room number'),
                    SrTextField(
                      controller: controller.form.roomField,
                      placeholder: 'e.g. CL-204',
                      semanticLabel: 'Room number',
                      mono: true,
                    ),
                  ],
                ),
              ],
            ),
            if (_hint(selected) case final hint?) ...[
              const SizedBox(height: 13),
              _BuildingHint(
                text: hint,

                onCenter: selected != null && selected.mapped
                    ? () => controller.map.centerOn(selected.coords, zoom: 18.5)
                    : null,
              ),
            ],
          ],
        ),
      );
    },
  );

  String? _hint(CampusBuilding? selected) {
    if (selected == null) return null;
    if (!selected.mapped) {
      return '${selected.name} has no surveyed centroid yet, so nothing can '
          'pre-centre the map. Pin it by eye and it becomes the reference for '
          'the next room in this building.';
    }
    final pin = controller.draft.pin;
    if (pin == null) {
      return '${selected.name} is mapped at ${formatCoords(selected.coords)}.';
    }
    final metres = haversine(pin, selected.coords);
    if (metres > buildingProximityLimit) {
      return 'The current pin is ${formatMetres(metres)} from '
          '${selected.name}.';
    }
    return null;
  }
}

class _BuildingHint extends StatelessWidget {
  const _BuildingHint({required this.text, required this.onCenter});

  final String text;
  final VoidCallback? onCenter;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: context.srColors.primaryTint2,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: context.srColors.primaryLine),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('⌖', style: sans(12, color: SR.primary)),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: sans(11.5, height: 1.5, color: context.srColors.primaryDeep),
          ),
        ),
        if (onCenter != null) ...[
          const SizedBox(width: 9),
          Hoverable(
            builder: (context, hovered) => GestureDetector(
              onTap: onCenter,
              child: AnimatedContainer(
                duration: SR.stateChange,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: hovered
                      ? context.srColors.primaryTint
                      : context.srColors.surface,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: SR.primary),
                ),
                child: Text(
                  'Centre map here',
                  style: sans(11, w: 600, color: SR.primary),
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
