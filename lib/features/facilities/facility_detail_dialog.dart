import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../data/campus_data.dart';
import '../../model/facility.dart';
import '../../model/facility_photo.dart';
import '../../theme/sr_tokens.dart';
import '../../util/geo.dart';
import '../../widgets/record_activity.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_controls.dart';
import 'facility_configuration_dialog.dart';

Future<void> showFacilityDetail(
  BuildContext context, {
  required AppState state,
  required Facility facility,
  required VoidCallback onEdit,
  required VoidCallback onDelete,
}) async {
  await state.refreshFacilityActivity(facility);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierColor: SR.scrim,
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
}

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
  PageController? _photoController;
  final Map<String, GlobalKey> _thumbnailKeys = {};
  int _selectedPhoto = 0;

  Facility get facility => widget.facility;
  VoidCallback get onEdit => widget.onEdit;
  VoidCallback get onDelete => widget.onDelete;

  @override
  void dispose() {
    _photoController?.dispose();
    super.dispose();
  }

  void _selectPhoto(int index, {bool animatePage = false}) {
    if (index < 0 || index >= facility.photos.length) return;
    if (_selectedPhoto != index) setState(() => _selectedPhoto = index);
    final photoController = _photoController;
    if (animatePage && photoController != null && photoController.hasClients) {
      photoController.animateToPage(
        index,
        duration: SR.stateChange,
        curve: SR.easing,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final thumbnailContext =
          _thumbnailKeys[facility.photos[index].id]?.currentContext;
      if (thumbnailContext != null) {
        Scrollable.ensureVisible(
          thumbnailContext,
          duration: SR.stateChange,
          curve: SR.easing,
          alignment: .5,
        );
      }
    });
  }

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
    final photoController = _photoController ??= PageController();
    return SrAdaptiveDialog(
      maxWidth: 760,
      maxHeight: 800,
      child: Container(
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _AdminFacilityGallery(
                      photos: facility.photos,
                      controller: photoController,
                      selected: _selectedPhoto,
                      thumbnailKeys: _thumbnailKeys,
                      onPageChanged: _selectPhoto,
                      onThumbnailTap: (index) =>
                          _selectPhoto(index, animatePage: true),
                      onClose: () => Navigator.of(context).pop(),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              Text(
                                facility.name,
                                style: sans(18, w: 600, tracking: -.02),
                              ),
                              SrPill(
                                label: facility.state.label,
                                background: facility.state.background,
                                foreground: facility.state.foreground,
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${facility.room}  ·  ${facility.building}',
                            style: sans(12, color: SR.ink4),
                          ),
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
                                    onTap: () =>
                                        setState(() => _tab = _Tab.details),
                                  ),
                                  _DialogTab(
                                    label: 'Activity',
                                    count: activity.length,
                                    selected: _tab == _Tab.activity,
                                    onTap: () =>
                                        setState(() => _tab = _Tab.activity),
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
                                  Text(
                                    pinNote,
                                    style: sans(11, color: SR.muted),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 12),
                            SrCellGrid(
                              columns: MediaQuery.sizeOf(context).width < 520
                                  ? 2
                                  : 3,
                              children: [
                                SrKeyCell(
                                  label: 'CATEGORY',
                                  value: facility.category,
                                ),
                                SrKeyCell(
                                  label: 'CAPACITY',
                                  value: '${facility.capacity} seats',
                                ),
                                SrKeyCell(
                                  label: 'FLOOR',
                                  value: facility.floor,
                                ),
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
                                SrKeyCell(
                                  label: 'ADVANCE',
                                  value: facility.advance,
                                ),
                                SrKeyCell(
                                  label: 'BOOKINGS',
                                  value: '${facility.bookings} on record',
                                ),
                                SrKeyCell(
                                  label: 'RATING',
                                  value: facility.ratingLabel,
                                ),
                                SrKeyCell(
                                  label: 'VERIFIED BOOKINGS',
                                  value: facility.supportsInternalLane
                                      ? 'Internal admin assigned'
                                      : 'Unavailable — no internal admin',
                                ),
                                SrKeyCell(
                                  label: 'GUEST BOOKINGS',
                                  value: facility.supportsExternalLane
                                      ? 'External admin assigned'
                                      : 'Unavailable — no external admin',
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
                              Text(
                                'None recorded.',
                                style: sans(11, color: SR.muted),
                              )
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

                          const SizedBox(height: 4),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _FacilityActionFooter(
              canEdit: facility.canManage,
              onEdit: onEdit,
              onConfigure: () => showFacilityConfigurationDialog(
                context,
                state: widget.state,
                facility: facility,
              ),
              onClose: () => Navigator.of(context).pop(),
              onDelete: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminFacilityGallery extends StatelessWidget {
  const _AdminFacilityGallery({
    required this.photos,
    required this.controller,
    required this.selected,
    required this.thumbnailKeys,
    required this.onPageChanged,
    required this.onThumbnailTap,
    required this.onClose,
  });

  final List<FacilityPhoto> photos;
  final PageController controller;
  final int selected;
  final Map<String, GlobalKey> thumbnailKeys;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<int> onThumbnailTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    final safeSelected = photos.isEmpty
        ? 0
        : selected.clamp(0, photos.length - 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: compact ? 220 : 280,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (photos.isEmpty)
                const PlaceholderStripes(
                  key: ValueKey('admin-facility-gallery-empty'),
                  hue: 215,
                  caption: 'no photos on this record',
                  captionSize: 11,
                )
              else
                PageView.builder(
                  key: const ValueKey('admin-facility-photo-pages'),
                  controller: controller,
                  itemCount: photos.length,
                  onPageChanged: onPageChanged,
                  itemBuilder: (context, index) => Semantics(
                    key: ValueKey('admin-facility-photo-$index'),
                    image: true,
                    label: 'Facility photo ${index + 1} of ${photos.length}',
                    child: FacilityPhotoImage(photo: photos[index]),
                  ),
                ),
              Positioned(
                left: 14,
                bottom: 14,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xD910141A),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    photos.isEmpty
                        ? 'NO PHOTOS'
                        : '${safeSelected + 1} / ${photos.length} PHOTOS',
                    style: mono(9.5, w: 500, color: Colors.white),
                  ),
                ),
              ),
              Positioned(
                right: 12,
                top: 12,
                child: SrIconButton(
                  glyph: '✕',
                  tooltip: 'Close',
                  size: compact ? 40 : 34,
                  border: null,
                  background: const Color(0xF0FFFFFF),
                  onPressed: onClose,
                ),
              ),
            ],
          ),
        ),
        if (photos.length > 1)
          Container(
            height: 78,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: SR.surfaceSubtle,
              border: Border(bottom: BorderSide(color: SR.hairline)),
            ),
            child: ListView.separated(
              key: const ValueKey('admin-facility-photo-thumbnails'),
              scrollDirection: Axis.horizontal,
              itemCount: photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final photo = photos[index];
                final thumbnailKey = thumbnailKeys.putIfAbsent(
                  photo.id,
                  GlobalKey.new,
                );
                return _AdminPhotoThumbnail(
                  key: thumbnailKey,
                  photo: photo,
                  index: index,
                  count: photos.length,
                  selected: index == safeSelected,
                  onTap: () => onThumbnailTap(index),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _AdminPhotoThumbnail extends StatelessWidget {
  const _AdminPhotoThumbnail({
    super.key,
    required this.photo,
    required this.index,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final FacilityPhoto photo;
  final int index;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: 'Show facility photo ${index + 1} of $count',
    child: GestureDetector(
      key: ValueKey('admin-facility-photo-thumbnail-$index'),
      onTap: onTap,
      child: AnimatedContainer(
        duration: SR.stateChange,
        width: 74,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: SR.surface,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? SR.blue : SR.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: FacilityPhotoImage(photo: photo, captionSize: 8),
        ),
      ),
    ),
  );
}

class _FacilityActionFooter extends StatelessWidget {
  const _FacilityActionFooter({
    required this.canEdit,
    required this.onEdit,
    required this.onConfigure,
    required this.onClose,
    required this.onDelete,
  });

  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onConfigure;
  final VoidCallback onClose;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    final edit = SrButton(
      label: 'Edit facility',
      kind: SrButtonKind.primary,
      expand: compact,
      fontSize: 12.5,
      minHeight: 44,
      onPressed: onEdit,
    );
    final close = SrButton(
      label: 'Close',
      expand: compact,
      fontSize: 12.5,
      minHeight: 44,
      onPressed: onClose,
    );
    final configure = SrButton(
      label: 'Rates & access',
      expand: compact,
      fontSize: 12.5,
      minHeight: 44,
      onPressed: onConfigure,
    );
    final delete = SrButton(
      label: 'Delete',
      kind: SrButtonKind.danger,
      expand: compact,
      fontSize: 12.5,
      minHeight: 44,
      onPressed: onDelete,
    );

    return Container(
      padding: EdgeInsets.all(compact ? 14 : 16),
      decoration: BoxDecoration(
        color: SR.surface,
        border: Border(top: BorderSide(color: SR.divider)),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (canEdit) ...[
                  edit,
                  const SizedBox(height: 8),
                  configure,
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    Expanded(child: close),
                    if (canEdit) ...[
                      const SizedBox(width: 8),
                      Expanded(child: delete),
                    ],
                  ],
                ),
              ],
            )
          : Row(
              children: [
                if (canEdit) ...[edit, const SizedBox(width: 8), configure],
                const Spacer(),
                close,
                if (canEdit) ...[const SizedBox(width: 8), delete],
              ],
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
    barrierColor: SR.scrim,
    builder: (dialogContext) => SrAdaptiveDialog(
      maxWidth: 400,
      maxHeight: 520,
      fullScreenOnCompact: false,
      padding: EdgeInsets.all(
        SR.isCompact(MediaQuery.sizeOf(dialogContext).width) ? 18 : 22,
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
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              SrButton(
                label: 'Keep it',
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
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
          constraints: BoxConstraints(
            minHeight: SR.isCompact(MediaQuery.sizeOf(context).width) ? 44 : 0,
          ),
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
