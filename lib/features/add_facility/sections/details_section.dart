import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/campus_data.dart';
import '../../../model/facility_draft.dart';
import '../../../theme/sr_tokens.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/sr_controls.dart';
import '../add_facility_controller.dart';

import '../../../theme/sr_theme.dart';

class DetailsSection extends StatelessWidget {
  const DetailsSection({
    super.key,
    required this.controller,
    required this.stacked,
    required this.dense,
  });

  final AddFacilityController controller;
  final bool stacked;
  final bool dense;

  static const _nameLimit = 60;

  @override
  Widget build(BuildContext context) {
    final draft = controller.draft;
    final errors = controller.errors;

    return SectionCard(
      anchorKey: controller.sectionKeys[RequiredItem.name],
      number: '01',
      title: 'Facility details',
      caption: 'What people will search for',
      dense: dense,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SrLabel(
            'Facility name',
            required: true,
            meta: Text(
              '${draft.name.length}/$_nameLimit',
              style: mono(10.5, color: context.srColors.mutedLight),
            ),
          ),
          SrTextField(
            controller: controller.nameField,
            placeholder: 'e.g. Computer Laboratory 2',
            semanticLabel: 'Facility name',
            hasError: errors.containsKey(RequiredItem.name),
            inputFormatters: [LengthLimitingTextInputFormatter(_nameLimit)],
          ),
          SrErrorText(errors[RequiredItem.name]),
          const SizedBox(height: 14),

          FieldRow(
            stacked: stacked,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SrLabel('Category', required: true),
                  SrSelect<String>(
                    value: draft.category.isEmpty ? null : draft.category,
                    items: categories,
                    placeholder: 'Choose a category',
                    semanticLabel: 'Category',
                    hasError: errors.containsKey(RequiredItem.category),
                    labelOf: (c) => c,
                    onChanged: (v) {
                      if (v != null) controller.setCategory(v);
                    },
                  ),
                  SrErrorText(errors[RequiredItem.category]),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SrLabel('Capacity', required: true),
                  SrTextField(
                    controller: controller.capacityField,
                    placeholder: '0',
                    mono: true,
                    semanticLabel: 'Capacity in seats',
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(5),
                    ],
                    hasError: errors.containsKey(RequiredItem.capacity),
                    padding: const EdgeInsets.only(left: 12),
                    suffix: Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: context.srColors.hairline),
                        ),
                      ),
                      child: Text(
                        'seats',
                        style: sans(11, color: context.srColors.muted),
                      ),
                    ),
                  ),
                  SrErrorText(errors[RequiredItem.capacity]),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),

          const SrLabel('Description'),
          SrTextField(
            controller: controller.descriptionField,
            placeholder:
                'Who it is for, what equipment is fixed in the room, anything '
                'a requester should know before booking.',
            semanticLabel: 'Description',
            fontSize: 12.5,
            minLines: 3,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
          ),
          const SizedBox(height: 14),

          const SrLabel('Status'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final status in FacilityStatus.values)
                _StatusOption(
                  status: status,
                  selected: draft.status == status,
                  onTap: () => controller.setStatus(status),
                ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            draft.status.hint,
            style: sans(11, height: 1.5, color: context.srColors.muted),
          ),
        ],
      ),
    );
  }
}

class _StatusOption extends StatelessWidget {
  const _StatusOption({
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final FacilityStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: status.label,
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SR.stateChange,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? context.srColors.primaryTint
                : context.srColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? SR.primary
                  : (hovered
                        ? context.srColors.borderHover
                        : context.srColors.border),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: status.dot,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                status.label,
                style: sans(
                  12,
                  w: 500,
                  color: selected ? SR.primaryHover : context.srColors.ink2,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
