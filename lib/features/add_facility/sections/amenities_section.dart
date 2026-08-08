import 'package:flutter/material.dart';

import '../../../data/campus_data.dart';
import '../../../theme/sr_tokens.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/sr_controls.dart';
import '../add_facility_controller.dart';

class AmenitiesSection extends StatelessWidget {
  const AmenitiesSection({
    super.key,
    required this.controller,
    required this.dense,
  });

  final AddFacilityController controller;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final selected = controller.draft.amenities;
    return SectionCard(
      number: '05',
      title: 'Amenities',
      caption: controller.amenityCountLabel,
      dense: dense,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              color: SR.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: controller.amenityOpen ? SR.blue : SR.borderField,
              ),
            ),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final label in selected)
                  _Token(
                    label: label,
                    onRemove: () => controller.removeAmenity(label),
                  ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 150,
                    maxWidth: 320,
                  ),
                  child: TextField(
                    controller: controller.amenityField,
                    focusNode: controller.amenityFocus,
                    onChanged: controller.setAmenityQuery,
                    onTap: controller.openAmenities,
                    onSubmitted: (_) => controller.submitAmenityQuery(),
                    cursorColor: SR.blue,
                    cursorWidth: 1.5,
                    style: sans(12.5),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 5,
                      ),
                      hintText: controller.amenityPlaceholder,
                      hintStyle: sans(12.5, color: SR.mutedLight),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (controller.amenityOpen) ...[
            const SizedBox(height: 6),
            _Results(controller: controller),
          ],
        ],
      ),
    );
  }
}

class _Token extends StatelessWidget {
  const _Token({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(9, 4, 6, 4),
    decoration: BoxDecoration(
      color: SR.blueTint,
      borderRadius: BorderRadius.circular(7),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: sans(11.5, w: 500, color: SR.blueDark)),
        const SizedBox(width: 6),
        Semantics(
          button: true,
          label: 'Remove $label',
          child: Hoverable(
            builder: (context, hovered) => GestureDetector(
              onTap: onRemove,
              child: Text(
                '✕',
                style: sans(10, color: hovered ? SR.blueDark : SR.blueToken),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _Results extends StatelessWidget {
  const _Results({required this.controller});

  final AddFacilityController controller;

  @override
  Widget build(BuildContext context) {
    final results = controller.amenityResults;
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SR.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1710141A),
            blurRadius: 26,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: controller.amenityNoResults
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              child: Text(
                'No amenity matches “${controller.amenityQuery}”. Press Enter '
                'to request it as a new tag.',
                style: sans(12, height: 1.5, color: SR.muted),
              ),
            )
          : ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: results.length,
              itemBuilder: (context, index) => _ResultRow(
                amenity: results[index],
                selected: controller.draft.amenities.contains(
                  results[index].label,
                ),
                onTap: () => controller.toggleAmenity(results[index].label),
              ),
            ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.amenity,
    required this.selected,
    required this.onTap,
  });

  final Amenity amenity;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    checked: selected,
    label: amenity.label,
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: hovered
                ? SR.blueTint2
                : (selected ? SR.surfaceSubtle : SR.surface),
            border: const Border(bottom: BorderSide(color: SR.dividerSoft)),
          ),
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? SR.blue : SR.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: selected ? SR.blue : SR.borderField,
                  ),
                ),
                child: selected
                    ? const Icon(
                        Icons.check_rounded,
                        size: 11,
                        color: SR.surface,
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(amenity.label, style: sans(12.5))),
              Text(
                amenity.group,
                style: mono(9.5, tracking: .04, color: SR.muted),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
