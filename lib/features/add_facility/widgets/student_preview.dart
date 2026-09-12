import 'package:flutter/material.dart';

import '../../../model/facility_draft.dart';
import '../../../theme/sr_theme.dart';
import '../../../theme/sr_tokens.dart';
import '../../../widgets/facility_catalogue_card.dart';
import '../add_facility_controller.dart';

const _previewDescriptionPlaceholder =
    'No description yet. Students rely on this to decide whether the room '
    'fits their session.';

IconData _categoryIcon(String category) => switch (category) {
  'Computer Laboratory' => Icons.computer_rounded,
  'Science Laboratory' => Icons.science_rounded,
  'Auditorium' => Icons.theater_comedy_rounded,
  'Library Space' => Icons.menu_book_rounded,
  'Gymnasium' => Icons.sports_basketball_rounded,
  'Conference Room' => Icons.groups_rounded,
  _ => Icons.apartment_rounded,
};

FacilityCatalogueCardData _cardDataFromDraft(FacilityDraft draft) {
  final trimmedName = draft.name.trim();
  final name = trimmedName.isEmpty ? 'Untitled facility' : trimmedName;
  final description = draft.description.trim();
  return FacilityCatalogueCardData(
    id: 'facility-draft-preview',
    name: name,
    category: draft.category.isEmpty ? 'Facility' : draft.category,
    statusLabel: draft.status.label,
    statusTone: draft.status.tone,
    locationLabel: draft.whereLine,
    description: description.isEmpty
        ? _previewDescriptionPlaceholder
        : description,
    includedAmenities: List.unmodifiable(draft.amenities),
    capacityLabel: draft.capacitySeats == null
        ? '—'
        : '${draft.capacitySeats} seats',
    hoursLabel: draft.hoursLine,
    approvalLabel: draft.requiresApproval ? 'Required' : 'Instant',
    availabilityLabel: 'Preview only',
    availabilityTone: SrTone.info,
    rateLabel: 'Included rate',
    coverPhoto: draft.photos.isEmpty ? null : draft.photos.first,
    placeholderHue: name.hashCode.abs() % 360,
    placeholderIcon: _categoryIcon(draft.category),
  );
}

class StudentPreview extends StatelessWidget {
  const StudentPreview({super.key, required this.controller});

  final AddFacilityController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller.form,
      controller.map,
      controller.photos,
      controller.amenities,
    ]),
    builder: (context, _) => _content(context),
  );

  Widget _content(BuildContext context) {
    final data = _cardDataFromDraft(controller.draft);
    final tooltip = 'Preview reserve action for ${data.name}';

    return Container(
      color: context.srColors.bg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: FacilityCatalogueCard(
                data: data,
                reserveEnabled: true,
                previewMode: true,
                reserveTooltip: tooltip,
                onReserve: () => controller.showToast(
                  const ToastMessage(
                    'Preview only — this is the student-facing button, not a '
                    'live booking.',
                    tone: AdvisoryTone.info,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 9),
            Center(
              child: Text(
                controller.map.coordLabel,
                style: mono(10.5, color: context.srColors.muted),
              ),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Text(
                'This is exactly what a student sees in the reservation '
                'catalogue.',
                textAlign: TextAlign.center,
                style: sans(10.5, height: 1.6, color: context.srColors.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
