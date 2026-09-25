import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../model/account.dart';
import '../../model/amenity_request.dart';
import '../../model/facility.dart';
import '../../model/facility_photo.dart';
import '../../model/payment.dart';
import '../../theme/sr_tokens.dart';
import '../../theme/sr_theme.dart';
import '../../util/geo.dart';
import '../../widgets/rating_display.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';

Future<void> showFacilityPreview(
  BuildContext context, {
  required AppState state,
  required Facility facility,
  required bool reserveEnabled,
  required String reserveReason,
  required void Function(BuildContext context) onReserve,
}) {
  if (MediaQuery.sizeOf(context).width < SR.tabletMin) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _MobileFacilityPreviewPage(
          state: state,
          facility: facility,
          reserveEnabled: reserveEnabled,
          reserveReason: reserveReason,
          onReserve: onReserve,
        ),
      ),
    );
  }

  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x7010141A),
    builder: (_) => _FacilityPreviewDialog(
      rootContext: context,
      state: state,
      facility: facility,
      reserveEnabled: reserveEnabled,
      reserveReason: reserveReason,
      onReserve: onReserve,
    ),
  );
}

class _MobileFacilityPreviewPage extends StatelessWidget {
  const _MobileFacilityPreviewPage({
    required this.state,
    required this.facility,
    required this.reserveEnabled,
    required this.reserveReason,
    required this.onReserve,
  });

  final AppState state;
  final Facility facility;
  final bool reserveEnabled;
  final String reserveReason;
  final void Function(BuildContext context) onReserve;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.srColors.surface,
    appBar: AppBar(
      backgroundColor: context.srColors.surface,
      foregroundColor: context.srColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: const BackButton(),
      titleSpacing: 0,
      title: Text(
        facility.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sans(15, w: 600, tracking: -.01),
      ),
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: context.srColors.border),
      ),
    ),
    body: SafeArea(
      top: false,
      child: _FacilityPreviewContent(
        state: state,
        facility: facility,
        mobile: true,
        reserveEnabled: reserveEnabled,
        reserveReason: reserveReason,
        onReserve: () => onReserve(context),
      ),
    ),
  );
}

class _FacilityPreviewDialog extends StatelessWidget {
  const _FacilityPreviewDialog({
    required this.rootContext,
    required this.state,
    required this.facility,
    required this.reserveEnabled,
    required this.reserveReason,
    required this.onReserve,
  });

  final BuildContext rootContext;
  final AppState state;
  final Facility facility;
  final bool reserveEnabled;
  final String reserveReason;
  final void Function(BuildContext context) onReserve;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.transparent,
    elevation: 0,
    insetPadding: const EdgeInsets.all(20),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 860,
        maxHeight: MediaQuery.sizeOf(context).height - 40,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: _FacilityPreviewContent(
          state: state,
          facility: facility,
          mobile: false,
          showClose: true,
          reserveEnabled: reserveEnabled,
          reserveReason: reserveReason,
          onClose: () => Navigator.of(context).pop(),
          onReserve: () {
            Navigator.of(context).pop();
            onReserve(rootContext);
          },
        ),
      ),
    ),
  );
}

class _FacilityPreviewContent extends StatefulWidget {
  const _FacilityPreviewContent({
    required this.state,
    required this.facility,
    required this.mobile,
    required this.reserveEnabled,
    required this.reserveReason,
    required this.onReserve,
    this.showClose = false,
    this.onClose,
  });

  final AppState state;
  final Facility facility;
  final bool mobile;
  final bool showClose;
  final bool reserveEnabled;
  final String reserveReason;
  final VoidCallback onReserve;
  final VoidCallback? onClose;

  @override
  State<_FacilityPreviewContent> createState() =>
      _FacilityPreviewContentState();
}

class _FacilityPreviewContentState extends State<_FacilityPreviewContent> {
  int _selectedPhoto = 0;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.srColors.surface,
    child: SrScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StudentFacilityGallery(
            facility: widget.facility,
            selected: _selectedPhoto,
            mobile: widget.mobile,
            showClose: widget.showClose,
            onSelected: (index) => setState(() => _selectedPhoto = index),
            onClose: widget.onClose ?? () {},
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              widget.mobile ? 16 : 24,
              widget.mobile ? 18 : 22,
              widget.mobile ? 16 : 24,
              widget.mobile ? 24 : 24,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StudentFacilityOverview(
                  facility: widget.facility,
                  audience: widget.state.userAccount.pricingAudience,
                  showRate:
                      widget.state.userAccount.verification !=
                      VerificationState.verified,
                ),
                const SizedBox(height: 18),
                Semantics(
                  button: true,
                  enabled: widget.reserveEnabled,
                  label: 'Reserve now for ${widget.facility.name}',
                  onTap: widget.reserveEnabled ? widget.onReserve : null,
                  child: ExcludeSemantics(
                    child: SrButton(
                      label: 'Reserve now',
                      kind: SrButtonKind.primary,
                      expand: true,
                      minHeight: 44,
                      tooltip: widget.reserveEnabled
                          ? 'Reserve now for ${widget.facility.name}'
                          : widget.reserveReason,
                      icon: const Icon(Icons.event_available_rounded, size: 17),
                      onPressed: widget.reserveEnabled
                          ? widget.onReserve
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class StudentFacilityGallery extends StatelessWidget {
  const StudentFacilityGallery({
    super.key,
    required this.facility,
    required this.selected,
    required this.mobile,
    required this.showClose,
    required this.onSelected,
    required this.onClose,
  });

  final Facility facility;
  final int selected;
  final bool mobile;
  final bool showClose;
  final ValueChanged<int> onSelected;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final photos = facility.photos;
    final safeSelected = photos.isEmpty
        ? 0
        : selected.clamp(0, photos.length - 1).toInt();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: mobile ? 218 : 300,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedSwitcher(
                duration: SR.stateChange,
                child: photos.isEmpty
                    ? const PlaceholderStripes(
                        key: ValueKey('empty-gallery'),
                        hue: 215,
                        caption: 'No facility photos available',
                        captionSize: 11,
                      )
                    : FacilityPhotoImage(
                        key: ValueKey(photos[safeSelected].id),
                        photo: photos[safeSelected],
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
              if (showClose)
                Positioned(
                  right: 12,
                  top: 12,
                  child: SrIconButton(
                    glyph: 'x',
                    tooltip: 'Close',
                    size: 34,
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
            height: 76,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: context.srColors.surfaceSubtle,
              border: Border(
                bottom: BorderSide(color: context.srColors.hairline),
              ),
            ),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => _PhotoThumbnail(
                photo: photos[index],
                index: index,
                selected: index == safeSelected,
                onTap: () => onSelected(index),
              ),
            ),
          ),
      ],
    );
  }
}

class _PhotoThumbnail extends StatelessWidget {
  const _PhotoThumbnail({
    required this.photo,
    required this.index,
    required this.selected,
    required this.onTap,
  });

  final FacilityPhoto photo;
  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    key: ValueKey('facility-photo-thumbnail-$index'),
    button: true,
    selected: selected,
    label: 'Show facility photo ${index + 1}',
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: SR.stateChange,
        width: 72,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: context.srColors.surface,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? SR.primary : context.srColors.border,
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

class StudentFacilityOverview extends StatelessWidget {
  const StudentFacilityOverview({
    super.key,
    required this.facility,
    this.audience,
    this.showRate = true,
  });

  final Facility facility;
  final String? audience;
  final bool showRate;

  @override
  Widget build(BuildContext context) {
    final included = includedFacilityAmenities(facility);
    final rate = audience == null
        ? null
        : facility.hourlyRateCentavosFor(audience!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            SrPill(
              label: facility.state.label,
              background: facility.state.background,
              foreground: facility.state.foreground,
            ),
            SrPill(
              label: facility.category,
              background: context.srColors.primaryTint,
              foreground: SR.primaryHover,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          facility.name,
          style: sans(23, w: 600, tracking: -.025, height: 1.15),
        ),
        const SizedBox(height: 5),
        Text(
          facility.whereLine,
          style: sans(12.5, color: context.srColors.ink4),
        ),
        if (facility.hasRatings) ...[
          const SizedBox(height: 6),
          SrRatingStars(
            average: facility.ratingAverage,
            count: facility.ratingCount,
          ),
        ],
        const SizedBox(height: 13),
        Text(
          facility.description.isEmpty
              ? 'No description has been added for this facility.'
              : facility.description,
          style: sans(13, height: 1.65, color: context.srColors.ink3),
        ),
        const SizedBox(height: 22),
        const _SectionTitle('Facility details'),
        const SizedBox(height: 9),
        _DetailGrid(
          items: [
            _DetailItem('CAPACITY', '${facility.capacity} seats'),
            _DetailItem('OPEN HOURS', facility.hoursLabel),
            _DetailItem('OPEN DAYS', facility.days),
            _DetailItem(
              'APPROVAL',
              facility.approvalRequired ? 'Required' : 'Instant booking',
            ),
            _DetailItem('MAX DURATION', facility.maxDuration),
            _DetailItem('BOOK AHEAD', facility.advance),
            _DetailItem('BOOKING BUFFER', facility.buffer),
            if (showRate)
              _DetailItem(
                'RATE',
                rate == null
                    ? 'Not specified'
                    : rate == 0
                    ? 'Included rate'
                    : '${pesoFromCentavos(rate)} / hour',
              ),
            _DetailItem('RATING', facility.ratingLabel),
          ],
        ),
        const SizedBox(height: 22),
        const _SectionTitle('Location'),
        const SizedBox(height: 9),
        _LocationDetails(facility: facility),
        const SizedBox(height: 22),
        const _SectionTitle('Amenities'),
        const SizedBox(height: 9),
        if (included.isEmpty)
          Text(
            'No amenities recorded.',
            style: sans(12, color: context.srColors.muted),
          )
        else
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final amenity in included)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: context.srColors.dividerSoft,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.srColors.hairline),
                  ),
                  child: Text(
                    amenity,
                    style: sans(11.5, color: context.srColors.ink3),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.srColors.surfaceSubtle,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: context.srColors.hairline),
          ),
          child: Wrap(
            spacing: 18,
            runSpacing: 5,
            children: [
              Text(
                '${facility.photos.length} ${facility.photos.length == 1 ? 'photo' : 'photos'}',
                style: mono(10.5, color: context.srColors.ink4),
              ),
              Text(
                '${facility.bookings} bookings on record',
                style: mono(10.5, color: context.srColors.ink4),
              ),
              if (facility.hasRatings)
                Text(
                  '${facility.ratingCount} ${facility.ratingCount == 1 ? 'review' : 'reviews'}',
                  style: mono(10.5, color: context.srColors.ink4),
                ),
              Text(
                'Updated ${facility.updated}',
                style: mono(10.5, color: context.srColors.ink4),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DetailItem {
  const _DetailItem(this.label, this.value);

  final String label;
  final String value;
}

class _DetailGrid extends StatelessWidget {
  const _DetailGrid({required this.items});

  final List<_DetailItem> items;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 520 ? 3 : 2;
      const gap = 8.0;
      final width = (constraints.maxWidth - (gap * (columns - 1))) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final item in items)
            SizedBox(
              width: width,
              child: Container(
                constraints: const BoxConstraints(minHeight: 68),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: context.srColors.surfaceSubtle,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: context.srColors.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.label, style: keyLabel),
                    const SizedBox(height: 5),
                    Text(
                      item.value.isEmpty ? 'Not specified' : item.value,
                      style: sans(
                        11.5,
                        w: 500,
                        color: context.srColors.ink2,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _LocationDetails extends StatelessWidget {
  const _LocationDetails({required this.facility});

  final Facility facility;

  Future<void> _openMap() async {
    final point = facility.coords;
    if (point == null) return;
    final uri = Uri.https('www.google.com', '/maps/search/', {
      'api': '1',
      'query': '${point.latitude},${point.longitude}',
    });
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String get _address {
    final parts = <String>[
      if (facility.street.trim().isNotEmpty) facility.street.trim(),
      if (facility.barangay.trim().isNotEmpty) facility.barangay.trim(),
      if (facility.municipality.trim().isNotEmpty) facility.municipality.trim(),
      if (facility.province.trim().isNotEmpty) facility.province.trim(),
      if (facility.region.trim().isNotEmpty) facility.region.trim(),
      if (facility.country.trim().isNotEmpty) facility.country.trim(),
    ];
    return parts.isEmpty ? 'No street address recorded' : parts.join(', ');
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: context.srColors.primaryTint2,
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: context.srColors.primaryLine),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          facility.campusName,
          style: sans(12.5, w: 600, color: context.srColors.ink2),
        ),
        const SizedBox(height: 3),
        Text(
          facility.whereLine,
          style: sans(11.5, color: context.srColors.ink4),
        ),
        const SizedBox(height: 3),
        Text(
          _address,
          style: sans(11.5, height: 1.5, color: context.srColors.ink4),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SrPill(
              label: facility.pinConfidence.label,
              background: facility.pinConfidence == PinConfidence.verified
                  ? context.srColors.greenTint
                  : facility.pinConfidence == PinConfidence.needsCheck
                  ? context.srColors.amberTint
                  : context.srColors.dividerSoft,
              foreground: facility.pinConfidence.color,
              monospace: true,
              fontSize: 9,
            ),
            if (facility.coords != null)
              Text(
                formatCoords(facility.coords!),
                style: mono(9.5, color: context.srColors.muted),
              ),
            if (facility.accuracy != null)
              Text(
                '+/-${facility.accuracy} m accuracy',
                style: mono(9.5, color: context.srColors.muted),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SrButton(
          label: facility.coords == null ? 'Map unavailable' : 'Open map',
          kind: SrButtonKind.primary,
          expand: true,
          minHeight: 42,
          icon: const Icon(Icons.map_rounded, size: 16),
          onPressed: facility.coords == null ? null : _openMap,
        ),
      ],
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Text(label, style: sans(13, w: 600, color: context.srColors.ink2));
}
