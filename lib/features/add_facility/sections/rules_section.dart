import 'package:flutter/material.dart';

import '../../../data/campus_data.dart';
import '../../../theme/sr_tokens.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/sr_controls.dart';
import '../facility_form_controller.dart';

import '../../../theme/sr_theme.dart';

class RulesSection extends StatelessWidget {
  const RulesSection({
    super.key,
    required this.controller,
    required this.stacked,
    required this.dense,
  });

  final FacilityFormController controller;
  final bool stacked;
  final bool dense;

  static const _rules = <({String key, String label, String hint})>[
    (
      key: 'approval',
      label: 'Requires approval',
      hint:
          'Every request waits for an assigned administrator decision before the slot is '
          'held.',
    ),
    (
      key: 'maintenance',
      label: 'Under maintenance',
      hint: 'Blocks new bookings and flags existing ones for relocation.',
    ),
    (
      key: 'listing',
      label: 'Show in the public catalogue',
      hint:
          'Students and external renters can find this facility when browsing.',
    ),
  ];

  bool _value(String key) => switch (key) {
    'approval' => controller.draft.requiresApproval,
    'maintenance' => controller.draft.maintenance,
    _ => controller.draft.publicListing,
  };

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final draft = controller.draft;
      return SectionCard(
        number: '06',
        title: 'Reservation rules',
        caption: 'Sensible defaults applied',
        dense: dense,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final rule in _rules)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: context.srColors.dividerSoft),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(rule.label, style: sans(12.5, w: 500)),
                          const SizedBox(height: 2),
                          Text(
                            rule.hint,
                            style: sans(
                              11,
                              height: 1.5,
                              color: context.srColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    SrToggle(
                      value: _value(rule.key),
                      label: rule.label,
                      onChanged: (v) => controller.setRule(rule.key, v),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 14),
            const SrLabel('Available days'),
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 420;
                final dayWidth = (compact
                        ? (constraints.maxWidth - 15) / 4
                        : (constraints.maxWidth - 30) / 7)
                    .clamp(0.0, double.infinity);
                return Wrap(
                  spacing: 5,
                  runSpacing: 5,
                  children: [
                    for (var i = 0; i < dayLabels.length; i++)
                      SizedBox(
                        width: dayWidth,
                        child: _DayToggle(
                          label: dayLabels[i],
                          on: draft.days[i],
                          onTap: () => controller.toggleDay(i),
                        ),
                      ),
                  ],
                );
              },
            ),

            const SizedBox(height: 14),
            FieldRow(
              stacked: stacked,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SrLabel('Operating hours'),
                    Row(
                      children: [
                        Expanded(
                          child: _TimeField(
                            value: draft.openTime,
                            label: 'Opening time',
                            onChanged: controller.setOpenTime,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 7),
                          child: Text(
                            '–',
                            style: sans(13, color: context.srColors.mutedLight),
                          ),
                        ),
                        Expanded(
                          child: _TimeField(
                            value: draft.closeTime,
                            label: 'Closing time',
                            onChanged: controller.setCloseTime,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SrLabel('Max duration'),
                    SrSelect<String>(
                      value: draft.maxDuration,
                      items: durations,
                      semanticLabel: 'Maximum booking duration',
                      fontSize: 12.5,
                      labelOf: (d) => d,
                      onChanged: (v) {
                        if (v != null) controller.setMaxDuration(v);
                      },
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SrLabel('Advance booking limit'),
                    SrSelect<String>(
                      value: draft.advance,
                      items: advanceLimits,
                      semanticLabel: 'Advance booking limit',
                      fontSize: 12.5,
                      labelOf: (a) => a,
                      onChanged: (v) {
                        if (v != null) controller.setAdvance(v);
                      },
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SrLabel('Buffer between bookings'),
                    SrSelect<String>(
                      value: draft.buffer,
                      items: buffers,
                      semanticLabel: 'Buffer between bookings',
                      fontSize: 12.5,
                      labelOf: (b) => b,
                      onChanged: (v) {
                        if (v != null) controller.setBuffer(v);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class _DayToggle extends StatelessWidget {
  const _DayToggle({
    required this.label,
    required this.on,
    required this.onTap,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: on,
    label: label,
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SR.stateChange,
          constraints: BoxConstraints(
            minHeight: SR.isCompact(MediaQuery.sizeOf(context).width) ? 44 : 0,
          ),
          padding: const EdgeInsets.symmetric(vertical: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? context.srColors.primaryTint : context.srColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: on
                  ? SR.primary
                  : (hovered
                        ? context.srColors.borderHover
                        : context.srColors.border),
            ),
          ),
          child: Text(
            label,
            style: sans(
              11.5,
              w: 500,
              color: on ? SR.primaryHover : context.srColors.ink3,
            ),
          ),
        ),
      ),
    ),
  );
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final String value;
  final String label;
  final ValueChanged<String> onChanged;

  Future<void> _pick(BuildContext context) async {
    final parts = value.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.first) ?? 7,
      minute: parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
    );
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: label.toUpperCase(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null) return;
    onChanged(
      '${picked.hour.toString().padLeft(2, '0')}:'
      '${picked.minute.toString().padLeft(2, '0')}',
    );
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$label, currently $value',
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: () => _pick(context),
        child: AnimatedContainer(
          duration: SR.stateChange,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: context.srColors.surface,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: hovered ? SR.primary : context.srColors.borderField,
            ),
          ),
          child: Text(value, style: mono(12.5)),
        ),
      ),
    ),
  );
}
