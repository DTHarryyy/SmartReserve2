import 'package:flutter/material.dart';

import '../../../model/facility.dart';
import '../../../model/facility_photo.dart';
import '../../../theme/sr_tokens.dart';
import '../../../widgets/sr_components.dart';
import '../../../widgets/sr_controls.dart';
import '../add_facility_controller.dart';

IconData _categoryIcon(String category) => switch (category) {
  'Computer Laboratory' => Icons.computer_rounded,
  'Science Laboratory' => Icons.science_rounded,
  'Auditorium' => Icons.theater_comedy_rounded,
  'Library Space' => Icons.menu_book_rounded,
  'Gymnasium' => Icons.sports_basketball_rounded,
  'Conference Room' => Icons.groups_rounded,
  _ => Icons.apartment_rounded,
};

class StudentPreview extends StatelessWidget {
  const StudentPreview({super.key, required this.controller});

  final AddFacilityController controller;

  @override
  Widget build(BuildContext context) {
    final draft = controller.draft;
    final cover = draft.photos.isEmpty ? null : draft.photos.first;
    final name = draft.name.trim().isEmpty
        ? 'Untitled facility'
        : draft.name.trim();

    return Container(
      color: SR.bg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: SR.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: SR.border),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x0F10141A),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 10,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (cover != null)
                            FacilityPhotoImage(photo: cover)
                          else
                            FacilityCoverArt(
                              hue: draft.name.hashCode.abs() % 360,
                              glyph: _categoryIcon(draft.category),
                            ),
                          Positioned(
                            left: 11,
                            top: 11,
                            child: SrStatusChip(
                              label: draft.status.label,
                              tone: FacilityState.fromLabel(
                                draft.status.label,
                              ).tone,
                              dense: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(17, 16, 17, 17),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: sans(
                              15,
                              w: 600,
                              height: 1.3,
                              tracking: -.015,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            draft.whereLine,
                            style: sans(11.5, color: SR.ink4),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            draft.description.trim().isEmpty
                                ? 'No description yet. Students rely on this '
                                      'to decide whether the room fits their '
                                      'session.'
                                : draft.description.trim(),
                            style: sans(
                              12,
                              height: 1.65,
                              color: draft.description.trim().isEmpty
                                  ? SR.muted
                                  : SR.ink3,
                            ),
                          ),
                          if (draft.amenities.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 5,
                              runSpacing: 5,
                              children: [
                                for (final a in draft.amenities)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: SR.dividerSoft,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      a,
                                      style: sans(10.5, color: SR.ink3),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.only(top: 13),
                            decoration: const BoxDecoration(
                              border: Border(
                                top: BorderSide(color: SR.divider),
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _Stat(
                                  label: 'CAPACITY',
                                  value: draft.capacitySeats == null
                                      ? '—'
                                      : '${draft.capacitySeats} seats',
                                ),
                                _Stat(label: 'HOURS', value: draft.hoursLine),
                                _Stat(
                                  label: 'APPROVAL',
                                  value: draft.requiresApproval
                                      ? 'Required'
                                      : 'Instant',
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          SrButton(
                            label: 'Reserve this facility',
                            kind: SrButtonKind.primary,
                            expand: true,
                            fontSize: 12.5,
                            minHeight: 40,

                            onPressed: () => controller.showToast(
                              const ToastMessage(
                                'Preview only — this is the student-facing '
                                'button, not a live booking.',
                                tone: AdvisoryTone.info,
                              ),
                            ),
                          ),
                          const SizedBox(height: 9),
                          Center(
                            child: Text(
                              controller.coordLabel,
                              style: mono(10.5, color: SR.muted),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Text(
                'This is exactly what a student sees in the reservation '
                'catalogue.',
                textAlign: TextAlign.center,
                style: sans(10.5, height: 1.6, color: SR.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: keyLabel),
        const SizedBox(height: 2),
        Text(value, style: sans(12.5, w: 500)),
      ],
    ),
  );
}
