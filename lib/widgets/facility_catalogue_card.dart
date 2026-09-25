import 'package:flutter/material.dart';

import '../model/facility_photo.dart';
import '../theme/sr_theme.dart';
import '../theme/sr_tokens.dart';
import 'rating_display.dart';
import 'sr_components.dart';
import 'sr_controls.dart';

class FacilityCatalogueCardData {
  const FacilityCatalogueCardData({
    required this.id,
    required this.name,
    required this.category,
    required this.statusLabel,
    required this.statusTone,
    required this.locationLabel,
    required this.description,
    required this.includedAmenities,
    required this.capacityLabel,
    required this.hoursLabel,
    required this.approvalLabel,
    required this.availabilityLabel,
    required this.availabilityTone,
    required this.rateLabel,
    required this.coverPhoto,
    required this.placeholderHue,
    required this.placeholderIcon,
    this.ratingAverage,
    this.ratingCount = 0,
  });

  final String id;
  final String name;
  final String category;
  final String statusLabel;
  final SrTone statusTone;
  final String locationLabel;
  final String description;
  final List<String> includedAmenities;
  final String capacityLabel;
  final String hoursLabel;
  final String approvalLabel;
  final String availabilityLabel;
  final SrTone availabilityTone;
  final String rateLabel;
  final FacilityPhoto? coverPhoto;
  final int placeholderHue;
  final IconData placeholderIcon;
  final double? ratingAverage;
  final int ratingCount;

  bool get hasRatings => ratingAverage != null && ratingCount > 0;
}

class FacilityCatalogueCard extends StatelessWidget {
  const FacilityCatalogueCard({
    super.key,
    required this.data,
    required this.reserveEnabled,
    this.onViewDetails,
    this.onReserve,
    this.reserveTooltip,
    this.previewMode = false,
    this.showRate = true,
  });

  final FacilityCatalogueCardData data;
  final VoidCallback? onViewDetails;
  final VoidCallback? onReserve;
  final bool reserveEnabled;
  final String? reserveTooltip;
  final bool previewMode;
  final bool showRate;

  static const double radius = 14;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boundedHeight = constraints.hasBoundedHeight;
        Widget card = Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: context.srColors.surface,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: context.srColors.border),
            boxShadow: SR.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 16 / 10,
                child: _CardCover(data: data),
              ),
              if (boundedHeight)
                Expanded(
                  child: _CardBody(
                    data: data,
                    reserveEnabled: reserveEnabled,
                    onReserve: onReserve,
                    reserveTooltip: reserveTooltip,
                    previewMode: previewMode,
                    showRate: showRate,
                    bounded: true,
                  ),
                )
              else
                _CardBody(
                  data: data,
                  reserveEnabled: reserveEnabled,
                  onReserve: onReserve,
                  reserveTooltip: reserveTooltip,
                  previewMode: previewMode,
                  showRate: showRate,
                  bounded: false,
                ),
            ],
          ),
        );

        if (onViewDetails == null) return card;
        card = Semantics(
          container: true,
          explicitChildNodes: true,
          button: true,
          label: 'View details for ${data.name}',
          child: card,
        );
        return Hoverable(
          builder: (context, hovered) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onViewDetails,
            child: AnimatedScale(
              duration: SR.stateChange,
              curve: SR.easing,
              scale: hovered ? 1.006 : 1,
              child: card,
            ),
          ),
        );
      },
    );
  }
}

class _CardCover extends StatelessWidget {
  const _CardCover({required this.data});

  final FacilityCatalogueCardData data;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (data.coverPhoto == null)
        FacilityCoverArt(hue: data.placeholderHue, glyph: data.placeholderIcon)
      else
        FacilityPhotoImage(photo: data.coverPhoto!),
      Positioned(
        left: 11,
        bottom: 11,
        right: 11,
        child: Wrap(
          spacing: SR.space6,
          runSpacing: SR.space6,
          children: [
            _CoverChip(
              label: data.category.isEmpty ? 'Facility' : data.category,
            ),
            if (data.statusLabel != 'Active')
              _CoverChip(label: data.statusLabel, dot: data.statusTone.solid),
          ],
        ),
      ),
    ],
  );
}

class _CardBody extends StatelessWidget {
  const _CardBody({
    required this.data,
    required this.reserveEnabled,
    required this.onReserve,
    required this.reserveTooltip,
    required this.previewMode,
    required this.showRate,
    required this.bounded,
  });

  final FacilityCatalogueCardData data;
  final bool reserveEnabled;
  final VoidCallback? onReserve;
  final String? reserveTooltip;
  final bool previewMode;
  final bool showRate;
  final bool bounded;

  @override
  Widget build(BuildContext context) {
    final amenities = previewMode
        ? data.includedAmenities
        : data.includedAmenities.take(4).toList();
    final hiddenAmenityCount = previewMode
        ? 0
        : (data.includedAmenities.length - amenities.length).clamp(0, 999);
    final description = data.description.trim().isEmpty
        ? 'No description has been added for this facility.'
        : data.description.trim();
    final reserveLabel = previewMode
        ? 'Preview reserve action for ${data.name}'
        : 'Reserve now for ${data.name}';
    final reserveSemanticsLabel = reserveEnabled
        ? reserveLabel
        : data.availabilityLabel;

    final variableContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          data.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: sans(15, w: 600, height: 1.3),
        ),
        const SizedBox(height: 3),
        Text(
          data.locationLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: sans(11.5, color: context.srColors.ink4),
        ),
        if (data.hasRatings) ...[
          const SizedBox(height: 5),
          SrRatingStars(
            average: data.ratingAverage,
            count: data.ratingCount,
            dense: true,
            compact: true,
          ),
        ],
        const SizedBox(height: 10),
        Text(
          description,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: sans(12, height: 1.55, color: context.srColors.ink3),
        ),
        if (data.includedAmenities.isNotEmpty) ...[
          const SizedBox(height: 8),
          // Clipped to one row: with Spacer pinning the footer to the card's
          // bottom edge for grid alignment, an amenity list long enough to
          // wrap to a second row would grow this card's minimum content
          // height past what shorter cards in the same row budget for.
          SizedBox(
            height: 21,
            child: ClipRect(
              child: Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  for (final amenity in amenities) _AmenityChip(label: amenity),
                  if (hiddenAmenityCount > 0)
                    _AmenityChip(label: '+$hiddenAmenityCount'),
                ],
              ),
            ),
          ),
        ],
      ],
    );

    final bottomContent = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.only(top: 10),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: context.srColors.divider)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Stat(label: 'CAPACITY', value: data.capacityLabel),
              _Stat(label: 'HOURS', value: data.hoursLabel),
              _Stat(label: 'APPROVAL', value: data.approvalLabel),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SrStatusChip(
                  label: data.availabilityLabel,
                  tone: data.availabilityTone,
                  dense: true,
                ),
              ),
            ),
            if (showRate) ...[
              const SizedBox(width: SR.space8),
              Flexible(
                child: Text(
                  data.rateLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: SrType.subhead(
                    color: data.rateLabel == 'Included rate'
                        ? context.srColors.greenDark
                        : context.srColors.ink,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: SR.space8),
        Semantics(
          button: true,
          enabled: reserveEnabled,
          label: reserveSemanticsLabel,
          onTap: reserveEnabled ? onReserve : null,
          child: ExcludeSemantics(
            child: SrButton(
              key: ValueKey('facility-card-reserve-${data.id}'),
              label: 'Reserve now',
              kind: SrButtonKind.primary,
              expand: true,
              dense: true,
              tooltip: reserveTooltip ?? reserveLabel,
              icon: const Icon(Icons.event_available_rounded, size: 15),
              onPressed: reserveEnabled ? onReserve : null,
            ),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(17, 16, 17, 17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [variableContent, if (bounded) const Spacer(), bottomContent],
      ),
    );
  }
}

class _CoverChip extends StatelessWidget {
  const _CoverChip({required this.label, this.dot});

  final String label;
  final Color? dot;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 210),
    padding: const EdgeInsets.symmetric(horizontal: SR.space8, vertical: 4),
    decoration: BoxDecoration(
      color: context.srColors.glass,
      borderRadius: BorderRadius.circular(SR.rFull),
      border: Border.all(color: context.srColors.glassLine2),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot case final dot?) ...[
          Container(
            width: SR.space6,
            height: SR.space6,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: SR.space6),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SrType.caption(w: 600, color: context.srColors.ink2),
          ),
        ),
      ],
    ),
  );
}

class _AmenityChip extends StatelessWidget {
  const _AmenityChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: context.srColors.dividerSoft,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(label, style: sans(10.5, color: context.srColors.ink3)),
  );
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
        Text(
          value.isEmpty ? 'Not specified' : value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: sans(12.5, w: 500, height: 1.25),
        ),
      ],
    ),
  );
}
