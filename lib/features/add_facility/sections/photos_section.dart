import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../model/facility_draft.dart';
import '../../../model/facility_photo.dart';
import '../../../theme/sr_tokens.dart';
import '../../../widgets/section_card.dart';
import '../../../widgets/sr_controls.dart';
import '../add_facility_controller.dart';

class PhotosSection extends StatelessWidget {
  const PhotosSection({
    super.key,
    required this.controller,
    required this.columns,
    required this.dense,
  });

  final AddFacilityController controller;
  final int columns;
  final bool dense;

  static bool get _supportsFileDrop =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  Widget build(BuildContext context) {
    final photos = controller.draft.photos;
    return SectionCard(
      anchorKey: controller.sectionKeys[RequiredItem.photos],
      number: '04',
      title: 'Photos',
      caption: 'First image becomes the cover',
      dense: dense,
      titleSuffix: Text(' *', style: sans(13.5, w: 600, color: SR.red)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _dropZone(context),
          SrErrorText(controller.errors[RequiredItem.photos]),
          if (photos.isNotEmpty) ...[const SizedBox(height: 13), _grid(photos)],
        ],
      ),
    );
  }

  Widget _dropZone(BuildContext context) {
    final zone = DashedBox(
      radius: 11,
      color: controller.dragging ? SR.blue : SR.dashed,
      background: controller.dragging ? SR.blueTint : Colors.transparent,
      child: Column(
        children: [
          Text(
            _supportsFileDrop ? 'Drag photos here' : 'Add photos of the room',
            style: sans(12.5, w: 500, color: SR.ink2),
          ),
          const SizedBox(height: 3),
          Text(
            'JPG or PNG · up to ${AddFacilityController.maxPhotos} images · '
            '10 MB each',
            textAlign: TextAlign.center,
            style: sans(11, color: SR.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 7,
            runSpacing: 7,
            children: [
              SrButton(
                label: 'Browse files',
                dense: true,
                fontSize: 11.5,
                onPressed: controller.photosFull ? null : controller.pickFiles,
              ),
              SrButton(
                label: 'Use camera',
                dense: true,
                fontSize: 11.5,
                onPressed: controller.photosFull ? null : controller.pickCamera,
              ),
            ],
          ),
        ],
      ),
    );

    if (!_supportsFileDrop) return zone;

    return DropTarget(
      onDragEntered: (_) => controller.setDragging(true),
      onDragExited: (_) => controller.setDragging(false),
      onDragDone: (detail) {
        controller.setDragging(false);
        controller.addFiles(detail.files);
      },
      child: zone,
    );
  }

  Widget _grid(List<FacilityPhoto> photos) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    padding: EdgeInsets.zero,
    itemCount: photos.length,
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: 9,
      mainAxisSpacing: 9,
      childAspectRatio: 4 / 3,
    ),
    itemBuilder: (context, index) => _PhotoTile(
      controller: controller,
      photo: photos[index],
      index: index,
      total: photos.length,
    ),
  );
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.controller,
    required this.photo,
    required this.index,
    required this.total,
  });

  final AddFacilityController controller;
  final FacilityPhoto photo;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    final isCover = index == 0;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: isCover ? SR.blue : SR.border),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FacilityPhotoImage(photo: photo),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0x9910141A)],
                ),
              ),
              child: Row(
                children: [
                  _TileButton(
                    glyph: '←',
                    tooltip: 'Move earlier',
                    onPressed: index == 0
                        ? null
                        : () => controller.movePhoto(photo.id, -1),
                  ),
                  const SizedBox(width: 3),
                  _TileButton(
                    glyph: '→',
                    tooltip: 'Move later',
                    onPressed: index == total - 1
                        ? null
                        : () => controller.movePhoto(photo.id, 1),
                  ),
                  const Spacer(),
                  _TileButton(
                    glyph: '✕',
                    tooltip: 'Remove photo',
                    foreground: SR.red,
                    onPressed: () => controller.removePhoto(photo.id),
                  ),
                ],
              ),
            ),
          ),

          Positioned(
            left: 5,
            top: 5,
            child: Hoverable(
              enabled: !isCover,
              builder: (context, hovered) => GestureDetector(
                onTap: isCover ? null : () => controller.makeCover(photo.id),
                child: Tooltip(
                  message: isCover
                      ? 'This is the catalogue cover'
                      : 'Make this the cover',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: isCover
                          ? SR.blue
                          : (hovered ? SR.blueDark : const Color(0xE6FFFFFF)),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      isCover ? 'COVER' : 'SET COVER',
                      style: mono(
                        8.5,
                        w: 600,
                        tracking: .04,
                        color: isCover || hovered ? SR.surface : SR.ink2,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TileButton extends StatelessWidget {
  const _TileButton({
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
    this.foreground = SR.ink2,
  });

  final String glyph;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      child: Hoverable(
        enabled: onPressed != null,
        builder: (context, hovered) => GestureDetector(
          onTap: onPressed,
          child: Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered ? SR.surface : const Color(0xD9FFFFFF),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              glyph,
              style: sans(
                9,
                color: onPressed == null ? SR.mutedLight : foreground,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
