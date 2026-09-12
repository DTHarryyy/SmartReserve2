import 'package:flutter/material.dart';

import '../../model/facility_draft.dart';
import '../../theme/sr_tokens.dart';
import 'add_facility_controller.dart';
import 'sections/amenities_section.dart';
import 'sections/details_section.dart';
import 'sections/detected_section.dart';
import 'sections/location_section.dart';
import 'sections/photos_section.dart';
import 'sections/rules_section.dart';
import 'widgets/draft_banner.dart';
import 'widgets/progress_strip.dart';

import '../../theme/sr_theme.dart';

class FormRail extends StatelessWidget {
  const FormRail({
    super.key,
    required this.controller,
    required this.stacked,
    required this.dense,
    required this.padding,
    required this.photoColumns,
    this.scrollable = true,
  });

  final AddFacilityController controller;

  final bool stacked;

  final bool dense;
  final EdgeInsets padding;
  final int photoColumns;

  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DraftBanner(controller: controller),
        ProgressStrip(controller: controller, onJump: _jumpTo),
        DetailsSection(controller: controller, stacked: stacked, dense: dense),
        LocationSection(controller: controller, stacked: stacked, dense: dense),
        DetectedSection(controller: controller, stacked: stacked, dense: dense),
        PhotosSection(
          controller: controller,
          columns: photoColumns,
          dense: dense,
        ),
        AmenitiesSection(controller: controller.amenities, dense: dense),
        RulesSection(
          controller: controller.form,
          stacked: stacked,
          dense: dense,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
          child: Text(
            'Drafts autosave locally every few seconds. Nothing is published '
            'until you save.',
            style: sans(11, height: 1.6, color: context.srColors.muted),
          ),
        ),
      ],
    );

    if (!scrollable) {
      return Padding(padding: padding, child: content);
    }
    return Scrollbar(
      controller: controller.formScroll,
      child: SingleChildScrollView(
        controller: controller.formScroll,
        padding: padding,
        child: content,
      ),
    );
  }

  void _jumpTo(RequiredItem item) {
    final key = controller.sectionKeys[item];
    final target = key?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: SR.entrance,
      curve: SR.easing,
      alignment: .08,
    );
  }
}
