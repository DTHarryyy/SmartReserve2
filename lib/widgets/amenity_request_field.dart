import 'package:flutter/material.dart';

import '../data/campus_data.dart';
import '../model/facility.dart';
import '../model/payment.dart';
import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

/// Lets a requester pick additional amenities to ask for on a reservation.
///
/// Renders the current selection as removable chips, followed by a
/// "Request more amenities" trigger as the last item in the row. The trigger
/// opens a popover listing only amenities configured for the facility. The
/// optional catalogue fallback exists for old demo fixtures, but production
/// booking leaves it disabled so requesters cannot invent price inputs.
class AmenityRequestField extends StatelessWidget {
  const AmenityRequestField({
    super.key,
    required this.facilityAmenities,
    required this.selected,
    required this.onToggle,
    required this.onRemove,
    this.amenityOptions = const [],
    this.allowOtherAmenities = false,
    this.dense = false,
  });

  final List<String> facilityAmenities;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onRemove;
  final List<FacilityAmenity> amenityOptions;
  final bool allowOtherAmenities;
  final bool dense;

  /// Keep legacy fixture labels deduplicated; production options are backed
  /// by trusted facility-amenity IDs when the reservation is submitted.
  List<String> get _facilityLabels => amenityOptions.isEmpty
      ? facilityAmenities.toSet().toList()
      : [
          for (final option in amenityOptions)
            if (option.enabled) option.name,
        ];

  List<String> get _orderedSelection {
    final labels = _facilityLabels;
    final inRoom = [
      for (final label in labels)
        if (selected.contains(label)) label,
    ];
    final rest = [
      for (final label in selected)
        if (!labels.contains(label)) label,
    ]..sort();
    return [...inRoom, ...rest];
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Additional amenities · optional',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sans(dense ? 11 : 11.5, w: 500, color: SR.ink2),
      ),
      const SizedBox(height: 8),
      Wrap(
        key: const ValueKey('amenity-field-wrap'),
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final label in _orderedSelection)
            _AmenityChip(
              key: ValueKey('amenity-chip-$label'),
              label: label,
              onRemove: () => onRemove(label),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: _AmenityPickerButton(
              key: const ValueKey('amenity-request-trigger'),
              facilityAmenities: _facilityLabels,
              amenityOptions: amenityOptions,
              allowOtherAmenities: allowOtherAmenities,
              selected: selected,
              onToggle: onToggle,
            ),
          ),
        ],
      ),
    ],
  );
}

class _AmenityPickerButton extends StatelessWidget {
  const _AmenityPickerButton({
    super.key,
    required this.facilityAmenities,
    required this.selected,
    required this.onToggle,
    this.amenityOptions = const [],
    this.allowOtherAmenities = false,
  });

  final List<String> facilityAmenities;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final List<FacilityAmenity> amenityOptions;
  final bool allowOtherAmenities;

  @override
  Widget build(BuildContext context) {
    final inRoom = facilityAmenities;
    final inRoomSet = inRoom.toSet();
    final other = !allowOtherAmenities || amenityOptions.isNotEmpty
        ? const <Amenity>[]
        : [
            for (final amenity in amenities)
              if (!inRoomSet.contains(amenity.label)) amenity,
          ];
    final optionByName = {
      for (final option in amenityOptions) option.name: option,
    };
    return PopupMenuButton<void>(
      tooltip: 'Request more amenities',
      color: SR.surface,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(
        minWidth: 240,
        maxWidth: 320,
        maxHeight: 320,
      ),
      itemBuilder: (context) => [
        // A single disabled item holds the whole list so that tapping a row
        // toggles it without dismissing the menu. `enabled: false` also
        // dims icons to 38%, so the opacity is reset here.
        PopupMenuItem<void>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: IconTheme(
            data: const IconThemeData(opacity: 1),
            child: StatefulBuilder(
              // A scrollable here would break the IntrinsicWidth the popup
              // menu wraps its items in — the menu supplies its own scrolling.
              builder: (context, setMenuState) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (inRoom.isNotEmpty) ...[
                    const _GroupHeader('IN THIS ROOM'),
                    for (final label in inRoom)
                      _AmenityRow(
                        key: ValueKey('amenity-row-$label'),
                        label: label,
                        tag: optionByName[label] == null
                            ? 'in room'
                            : optionByName[label]!.priceCentavos == 0
                            ? 'included'
                            : pesoFromCentavos(
                                optionByName[label]!.priceCentavos,
                              ),
                        selected: selected.contains(label),
                        onTap: () {
                          onToggle(label);
                          setMenuState(() {});
                        },
                      ),
                  ],
                  if (other.isNotEmpty) ...[
                    const _GroupHeader('OTHER'),
                    for (final amenity in other)
                      _AmenityRow(
                        key: ValueKey('amenity-row-${amenity.label}'),
                        label: amenity.label,
                        tag: amenity.group,
                        selected: selected.contains(amenity.label),
                        onTap: () {
                          onToggle(amenity.label);
                          setMenuState(() {});
                        },
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
      child: Semantics(
        button: true,
        label: 'Request more amenities',
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected.isEmpty ? SR.surface : SR.blueTint,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected.isEmpty ? SR.borderField : SR.blueSoft,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_rounded,
                size: 14,
                color: selected.isEmpty ? SR.muted : SR.blueDark,
              ),
              const SizedBox(width: 5),
              Text(
                'Request more amenities',
                style: sans(
                  11,
                  w: 500,
                  color: selected.isEmpty ? SR.ink3 : SR.blueDark,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(label, style: mono(9.5, tracking: .04, color: SR.muted)),
    ),
  );
}

class _AmenityRow extends StatelessWidget {
  const _AmenityRow({
    super.key,
    required this.label,
    required this.tag,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String tag;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    checked: selected,
    label: label,
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          color: hovered
              ? SR.blueTint2
              : (selected ? SR.surfaceSubtle : SR.surface),
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
                    ? Icon(Icons.check_rounded, size: 11, color: SR.surface)
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(12.5),
                ),
              ),
              const SizedBox(width: 8),
              Text(tag, style: mono(9.5, tracking: .04, color: SR.muted)),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AmenityChip extends StatelessWidget {
  const _AmenityChip({super.key, required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  // The overhang padding sits *inside* the Stack: a Positioned child placed
  // outside the Stack's bounds would be painted but never hit-tested.
  Widget build(BuildContext context) => Stack(
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 5, right: 5),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          decoration: BoxDecoration(
            color: SR.blueTint,
            borderRadius: BorderRadius.circular(7),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sans(11.5, w: 500, color: SR.blueDark),
            ),
          ),
        ),
      ),
      Positioned(
        top: 0,
        right: 0,
        child: Semantics(
          button: true,
          label: 'Remove $label',
          child: Hoverable(
            builder: (context, hovered) => GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: SR.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: SR.blueSoft),
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: 11,
                  color: hovered ? SR.blueDark : SR.blueToken,
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// Read-only display of requested amenities as pills, with a "+N" overflow
/// when [max] is set and there are more than [max] labels.
class AmenityPills extends StatelessWidget {
  const AmenityPills(this.amenities, {super.key, this.max});

  final List<String> amenities;
  final int? max;

  @override
  Widget build(BuildContext context) {
    final shown = max == null ? amenities : amenities.take(max!).toList();
    final overflow = amenities.length - shown.length;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final label in shown)
          SrPill(
            label: label,
            background: SR.blueTint,
            foreground: SR.blueDark,
          ),
        if (overflow > 0)
          SrPill(
            label: '+$overflow',
            background: SR.dividerSoft,
            foreground: SR.ink4,
          ),
      ],
    );
  }
}
