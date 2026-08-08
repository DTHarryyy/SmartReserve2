import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/campus_data.dart';
import '../../model/facility.dart';
import '../../model/facility_photo.dart';
import '../../theme/sr_tokens.dart';
import '../../util/geo.dart';
import '../../widgets/record_activity.dart';
import '../../widgets/sr_controls.dart';

Future<void> showFacilityDetail(
  BuildContext context, {
  required AppState state,
  required Facility facility,
  required VoidCallback onEdit,
  required VoidCallback onDelete,
}) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x7010141A),
  builder: (dialogContext) => _FacilityDetailDialog(
    state: state,
    facility: facility,
    onEdit: () {
      Navigator.of(dialogContext).pop();
      onEdit();
    },
    onDelete: () {
      Navigator.of(dialogContext).pop();
      onDelete();
    },
  ),
);

class _FacilityDetailDialog extends StatefulWidget {
  const _FacilityDetailDialog({
    required this.state,
    required this.facility,
    required this.onEdit,
    required this.onDelete,
  });

  final AppState state;
  final Facility facility;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_FacilityDetailDialog> createState() => _FacilityDetailDialogState();
}

enum _Tab { details, activity }

class _FacilityDetailDialogState extends State<_FacilityDetailDialog> {
  _Tab _tab = _Tab.details;

  Facility get facility => widget.facility;
  VoidCallback get onEdit => widget.onEdit;
  VoidCallback get onDelete => widget.onDelete;

  (String badge, Color background, Color foreground, String note) get _pin {
    if (facility.coords == null) {
      return (
        'NO PIN',
        SR.dividerSoft,
        SR.muted,
        'Students cannot navigate to this facility until it is pinned.',
      );
    }
    final outside = !inPolygon(facility.coords!, campus.boundary);
    if (outside) {
      return (
        'OUTSIDE',
        SR.redTint,
        SR.red,
        'The pin sits outside the campus boundary and is flagged for review.',
      );
    }
    if (facility.pinConfidence == PinConfidence.needsCheck) {
      return (
        'NEEDS CHECK',
        SR.amberTint,
        SR.amber,
        'Precision is ±${facility.accuracy ?? 0} m — loose enough to send '
            'someone to the wrong door.',
      );
    }
    return (
      'VERIFIED',
      SR.greenTint,
      SR.greenDark,
      'Confirmed on the map at ±${facility.accuracy ?? 0} m.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final (badge, badgeBg, badgeFg, pinNote) = _pin;
    final activity = widget.state.facilityActivity(facility);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(20),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: SR.surface,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(
              color: Color(0x4D10141A),
              blurRadius: 64,
              offset: Offset(0, 26),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 150,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    facility.coverPhoto == null
                        ? const PlaceholderStripes(
                            hue: 215,
                            caption: 'no photos on this record',
                            captionSize: 11,
                          )
                        : FacilityPhotoImage(photo: facility.coverPhoto!),
                    Positioned(
                      left: 13,
                      top: 13,
                      child: SrPill(
                        label: facility.state.label,
                        background: facility.state.background,
                        foreground: facility.state.foreground,
                      ),
                    ),
                    Positioned(
                      right: 11,
                      top: 11,
                      child: SrIconButton(
                        glyph: '✕',
                        tooltip: 'Close',
                        size: 30,
                        border: null,
                        background: const Color(0xF0FFFFFF),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.end,
                      spacing: 10,
                      children: [
                        Text(
                          facility.name,
                          style: sans(18, w: 600, tracking: -.02),
                        ),
                        Text(facility.room, style: mono(11.5, color: SR.muted)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(facility.building, style: sans(12, color: SR.ink4)),
                    if (_tab == _Tab.details) ...[
                      const SizedBox(height: 11),
                      Text(
                        facility.description,
                        style: sans(12.5, height: 1.65, color: SR.ink3),
                      ),
                    ],

                    const SizedBox(height: 14),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: SR.dividerSoft,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _DialogTab(
                              label: 'Details',
                              selected: _tab == _Tab.details,
                              onTap: () => setState(() => _tab = _Tab.details),
                            ),
                            _DialogTab(
                              label: 'Activity',
                              count: activity.length,
                              selected: _tab == _Tab.activity,
                              onTap: () => setState(() => _tab = _Tab.activity),
                            ),
                          ],
                        ),
                      ),
                    ),

                    if (_tab == _Tab.activity)
                      RecordActivity(
                        entries: activity,
                        intro:
                            'Every change to this facility, most recent '
                            'first. Pin moves, capacity edits and status '
                            'changes are marked material.',
                        emptyTitle: 'No recorded activity',
                        emptyBody:
                            'Nothing has changed on this facility since it '
                            'was created. Edits, pin moves and status changes '
                            'will appear here.',
                      )
                    else ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: SR.surfaceSubtle,
                          borderRadius: BorderRadius.circular(11),
                          border: Border.all(color: SR.hairline),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text('MAP LOCATION', style: keyLabel),
                                const SizedBox(width: 9),
                                SrPill(
                                  label: badge,
                                  background: badgeBg,
                                  foreground: badgeFg,
                                  monospace: true,
                                  fontSize: 9,
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              facility.coords == null
                                  ? 'Not pinned'
                                  : formatCoords(facility.coords!),
                              style: mono(
                                13,
                                w: 500,
                                color: facility.coords == null
                                    ? SR.muted
                                    : SR.ink,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(pinNote, style: sans(11, color: SR.muted)),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),
                      SrCellGrid(
                        columns: MediaQuery.sizeOf(context).width < 520 ? 2 : 3,
                        children: [
                          SrKeyCell(
                            label: 'CATEGORY',
                            value: facility.category,
                          ),
                          SrKeyCell(
                            label: 'CAPACITY',
                            value: '${facility.capacity} seats',
                          ),
                          SrKeyCell(label: 'FLOOR', value: facility.floor),
                          SrKeyCell(
                            label: 'HOURS',
                            value: facility.hours,
                            valueMono: true,
                          ),
                          SrKeyCell(label: 'DAYS', value: facility.days),
                          SrKeyCell(
                            label: 'APPROVAL',
                            value: facility.approvalRequired
                                ? 'Required'
                                : 'Instant',
                          ),
                          SrKeyCell(
                            label: 'MAX DURATION',
                            value: facility.maxDuration,
                          ),
                          SrKeyCell(label: 'ADVANCE', value: facility.advance),
                          SrKeyCell(
                            label: 'BOOKINGS',
                            value: '${facility.bookings} on record',
                          ),
                        ],
                      ),

                      const SizedBox(height: 14),
                      Text(
                        'Amenities',
                        style: sans(11, w: 500, color: SR.ink2),
                      ),
                      const SizedBox(height: 7),
                      if (facility.amenities.isEmpty)
                        Text('None recorded.', style: sans(11, color: SR.muted))
                      else
                        Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: [
                            for (final amenity in facility.amenities)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: SR.dividerSoft,
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Text(
                                  amenity,
                                  style: sans(11, color: SR.ink3),
                                ),
                              ),
                          ],
                        ),

                      const SizedBox(height: 14),
                      Text(
                        'Last changed ${facility.updated}',
                        style: mono(10.5, color: SR.muted),
                      ),
                    ],

                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.only(top: 14),
                      decoration: const BoxDecoration(
                        border: Border(top: BorderSide(color: SR.divider)),
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          SrButton(
                            label: 'Edit facility',
                            kind: SrButtonKind.primary,
                            fontSize: 12.5,
                            minHeight: 40,
                            onPressed: onEdit,
                          ),
                          SrButton(
                            label: 'Close',
                            fontSize: 12.5,
                            minHeight: 40,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          SrButton(
                            label: 'Delete',
                            kind: SrButtonKind.danger,
                            fontSize: 12.5,
                            minHeight: 40,
                            onPressed: onDelete,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> confirmDeleteFacility(
  BuildContext context, {
  required AppState state,
  required Facility facility,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0x8010141A),
    builder: (dialogContext) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: SR.surface,
          borderRadius: BorderRadius.circular(14),
          boxShadow: SR.dialogShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Delete ${facility.name}?',
              style: sans(15, w: 600, tracking: -.01),
            ),
            const SizedBox(height: 7),
            Text(
              facility.bookings > 0
                  ? 'It has ${facility.bookings} bookings on record, so it is '
                        'archived rather than erased — the reservation history '
                        'stays intact and students stop seeing it in the '
                        'catalogue.'
                  : 'It has no bookings on record. Removing it takes it out of '
                        'the catalogue and off the campus map.',
              style: sans(12.5, height: 1.65, color: SR.ink4),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SrButton(
                  label: 'Keep it',
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                ),
                const SizedBox(width: 8),
                SrButton(
                  label: 'Delete facility',
                  kind: SrButtonKind.dangerSolid,
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  if (confirmed ?? false) await state.deleteFacility(facility);
}

class _DialogTab extends StatelessWidget {
  const _DialogTab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SR.stateChange,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? SR.surface
                : (hovered ? SR.divider : Colors.transparent),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected ? SR.border : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: sans(11.5, w: 500, color: selected ? SR.ink : SR.ink4),
              ),
              if (count != null) ...[
                const SizedBox(width: 6),
                Text('$count', style: mono(10.5, color: SR.muted)),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
