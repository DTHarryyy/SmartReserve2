import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

import '../theme/sr_theme.dart';

class AmenityRequestField extends StatelessWidget {
  const AmenityRequestField({
    super.key,
    required this.includedAmenities,
    required this.requestableAmenities,
    required this.selectedRequestedAmenities,
    required this.onToggle,
    required this.onRemove,
    this.dense = false,
  });

  final List<String> includedAmenities;
  final List<String> requestableAmenities;
  final Set<String> selectedRequestedAmenities;
  final ValueChanged<String> onToggle;
  final ValueChanged<String> onRemove;
  final bool dense;

  List<String> get _orderedSelection {
    final selected = selectedRequestedAmenities;
    return [
      for (final label in requestableAmenities)
        if (selected.contains(label)) label,
    ];
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Included with this facility',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sans(dense ? 11 : 11.5, w: 500, color: context.srColors.ink2),
      ),
      const SizedBox(height: 8),
      if (includedAmenities.isEmpty)
        Text(
          'No included amenities recorded.',
          style: sans(11.5, color: context.srColors.muted),
        )
      else
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final label in includedAmenities)
              _IncludedAmenityChip(
                key: ValueKey('included-amenity-chip-$label'),
                label: label,
              ),
          ],
        ),
      const SizedBox(height: 12),
      Text(
        'Additional amenities · optional',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sans(dense ? 11 : 11.5, w: 500, color: context.srColors.ink2),
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
              requestableAmenities: requestableAmenities,
              selected: selectedRequestedAmenities,
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
    required this.requestableAmenities,
    required this.selected,
    required this.onToggle,
  });

  final List<String> requestableAmenities;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final options = requestableAmenities;
    return PopupMenuButton<void>(
      tooltip: 'Request more amenities',
      color: context.srColors.surface,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(
        minWidth: 240,
        maxWidth: 320,
        maxHeight: 320,
      ),
      itemBuilder: (context) => [
        PopupMenuItem<void>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: IconTheme(
            data: const IconThemeData(opacity: 1),
            child: StatefulBuilder(
              builder: (context, setMenuState) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (options.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'All standard amenities are included with this facility.',
                        style: sans(
                          11.5,
                          height: 1.45,
                          color: context.srColors.ink4,
                        ),
                      ),
                    )
                  else ...[
                    const _GroupHeader('STANDARD CATALOG'),
                    for (final label in options)
                      _AmenityRow(
                        key: ValueKey('amenity-row-$label'),
                        label: label,
                        selected: selected.contains(label),
                        onTap: () {
                          onToggle(label);
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
            color: selected.isEmpty
                ? context.srColors.surface
                : context.srColors.primaryTint,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected.isEmpty
                  ? context.srColors.borderField
                  : context.srColors.primarySoft,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_rounded,
                size: 14,
                color: selected.isEmpty
                    ? context.srColors.muted
                    : SR.primaryHover,
              ),
              const SizedBox(width: 5),
              Text(
                'Request more amenities',
                style: sans(
                  11,
                  w: 500,
                  color: selected.isEmpty
                      ? context.srColors.ink3
                      : SR.primaryHover,
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
      child: Text(
        label,
        style: mono(9.5, tracking: .04, color: context.srColors.muted),
      ),
    ),
  );
}

class _AmenityRow extends StatelessWidget {
  const _AmenityRow({
    super.key,
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
    checked: selected,
    label: label,
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          color: hovered
              ? context.srColors.primaryTint2
              : (selected
                    ? context.srColors.surfaceSubtle
                    : context.srColors.surface),
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? SR.primary : context.srColors.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: selected ? SR.primary : context.srColors.borderField,
                  ),
                ),
                child: selected
                    ? Icon(
                        Icons.check_rounded,
                        size: 11,
                        color: context.srColors.surface,
                      )
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
            color: context.srColors.primaryTint,
            borderRadius: BorderRadius.circular(7),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sans(11.5, w: 500, color: SR.primaryHover),
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
                  color: context.srColors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: context.srColors.primarySoft),
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: 11,
                  color: hovered
                      ? SR.primaryHover
                      : context.srColors.primaryDeep,
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

class _IncludedAmenityChip extends StatelessWidget {
  const _IncludedAmenityChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: context.srColors.dividerSoft,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: context.srColors.hairline),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sans(11.5, w: 500, color: context.srColors.ink3),
      ),
    ),
  );
}

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
            background: context.srColors.primaryTint,
            foreground: SR.primaryHover,
          ),
        if (overflow > 0)
          SrPill(
            label: '+$overflow',
            background: context.srColors.dividerSoft,
            foreground: context.srColors.ink4,
          ),
      ],
    );
  }
}
