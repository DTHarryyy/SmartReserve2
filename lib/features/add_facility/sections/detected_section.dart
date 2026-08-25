import 'package:flutter/material.dart';

import '../../../model/facility_draft.dart';
import '../../../theme/sr_tokens.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/sr_controls.dart';
import '../add_facility_controller.dart';

import '../../../theme/sr_theme.dart';

class DetectedSection extends StatelessWidget {
  const DetectedSection({
    super.key,
    required this.controller,
    required this.stacked,
    required this.dense,
  });

  final AddFacilityController controller;
  final bool stacked;
  final bool dense;

  static const _fields = <({String key, String label})>[
    (key: 'geoBuilding', label: 'Building'),
    (key: 'street', label: 'Street'),
    (key: 'barangay', label: 'Barangay'),
    (key: 'municipality', label: 'Municipality'),
    (key: 'province', label: 'Province'),
    (key: 'region', label: 'Region'),
    (key: 'country', label: 'Country'),
  ];

  @override
  Widget build(BuildContext context) => SectionCard(
    anchorKey: controller.sectionKeys[RequiredItem.pin],
    number: '03',
    title: 'Detected location',
    caption: 'Read from the pin — editable',
    dense: dense,
    child: controller.hasPin ? _resolved(context) : _empty(context),
  );

  Widget _empty(BuildContext context) => DashedBox(
    radius: 10,
    background: context.srColors.surfaceSubtle,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
    child: Column(
      children: [
        Text(
          'No pin yet',
          style: sans(12.5, w: 500, color: context.srColors.ink2),
        ),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Text(
            'Drop a pin on the campus map and these seven address fields fill '
            'in automatically.',
            textAlign: TextAlign.center,
            style: sans(11.5, height: 1.6, color: context.srColors.muted),
          ),
        ),
        SrErrorText(controller.errors[RequiredItem.pin]),
      ],
    ),
  );

  Widget _resolved(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SrCellGrid(
        columns: stacked ? 2 : 4,
        children: [
          for (final stat in controller.liveStats(context))
            SrKeyCell(
              label: stat.key,
              value: stat.value,
              valueColor: stat.color,
              valueMono: true,
            ),
        ],
      ),
      const SizedBox(height: 14),
      if (controller.geoState == GeoState.loading)
        const _Resolving()
      else
        FieldRow(
          stacked: stacked,
          children: [
            for (final field in _fields)
              _GeoField(controller: controller, field: field),
          ],
        ),
    ],
  );
}

class _Resolving extends StatelessWidget {
  const _Resolving();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    decoration: BoxDecoration(
      color: context.srColors.surfaceSubtle,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: context.srColors.hairline),
    ),
    child: Row(
      children: [
        SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: SR.primary,
            backgroundColor: context.srColors.borderField,
          ),
        ),
        const SizedBox(width: 9),
        Text(
          'Resolving address from coordinates…',
          style: sans(11.5, color: context.srColors.ink4),
        ),
      ],
    ),
  );
}

class _GeoField extends StatelessWidget {
  const _GeoField({required this.controller, required this.field});

  final AddFacilityController controller;
  final ({String key, String label}) field;

  @override
  Widget build(BuildContext context) {
    final edited = controller.draft.geoEdited.contains(field.key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Row(
            children: [
              Text(
                field.label,
                style: sans(11, w: 500, color: context.srColors.ink2),
              ),
              const SizedBox(width: 5),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: edited
                      ? context.srColors.primaryTint
                      : context.srColors.dividerSoft,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  edited ? 'EDITED' : 'AUTO',
                  style: mono(
                    9,
                    color: edited ? SR.primaryHover : context.srColors.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
        SrTextField(
          controller: controller.geoFields[field.key]!,
          semanticLabel: field.label,
          fontSize: 12,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          onChanged: (v) => controller.editGeoField(field.key, v),
        ),
      ],
    );
  }
}
