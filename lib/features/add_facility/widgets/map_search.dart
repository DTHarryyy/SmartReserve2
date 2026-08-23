import 'package:flutter/material.dart';

import '../../../theme/sr_tokens.dart';
import '../../../widgets/sr_controls.dart';
import '../add_facility_controller.dart';

class MapSearchBar extends StatelessWidget {
  const MapSearchBar({
    super.key,
    required this.controller,
    required this.compact,
  });

  final AddFacilityController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _Field(controller: controller, compact: compact),
          ),
          const SizedBox(width: 7),
          _LayerSwitch(controller: controller, compact: compact),
        ],
      ),
      if (controller.searchOpen)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _Results(controller: controller),
        ),
    ],
  );
}

class _Field extends StatelessWidget {
  const _Field({required this.controller, required this.compact});

  final AddFacilityController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: 11, vertical: compact ? 11 : 9),
    decoration: BoxDecoration(
      color: SR.glass,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: SR.glassLine),
      boxShadow: SR.floatShadow,
    ),
    child: Row(
      children: [
        Icon(Icons.search_rounded, size: 15, color: SR.muted),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: controller.searchField,
            onChanged: controller.setSearchQuery,
            onTap: controller.openSearch,
            onSubmitted: (_) => controller.submitSearch(),
            cursorColor: SR.blue,
            cursorWidth: 1.5,
            style: sans(12),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              hintText:
                  'Search building, facility, address, or 18.3541, 121.6306',
              hintStyle: sans(12, color: SR.muted),
            ),
          ),
        ),
        if (controller.searchQuery.isNotEmpty)
          Semantics(
            button: true,
            label: 'Clear the search',
            child: Hoverable(
              builder: (context, hovered) => GestureDetector(
                onTap: () {
                  controller.searchField.clear();
                  controller.setSearchQuery('');
                  controller.closeSearch();
                },
                child: Text(
                  '✕',
                  style: sans(11, color: hovered ? SR.ink2 : SR.muted),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _LayerSwitch extends StatelessWidget {
  const _LayerSwitch({required this.controller, required this.compact});

  final AddFacilityController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: SR.glass,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: SR.glassLine),
      boxShadow: SR.floatShadow,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final layer in MapLayer.values)
          Tooltip(
            message: layer.title,
            child: Semantics(
              button: true,
              selected: controller.layer == layer,
              child: Hoverable(
                builder: (context, hovered) => GestureDetector(
                  onTap: () => controller.setLayer(layer),
                  child: AnimatedContainer(
                    duration: SR.stateChange,
                    padding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: compact ? 10 : 6,
                    ),
                    decoration: BoxDecoration(
                      color: controller.layer == layer
                          ? SR.blue
                          : (hovered ? SR.dividerSoft : Colors.transparent),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      layer.label,
                      style: sans(
                        11,
                        w: 500,
                        color: controller.layer == layer ? SR.onDark : SR.ink2,
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

class _Results extends StatelessWidget {
  const _Results({required this.controller});

  final AddFacilityController controller;

  @override
  Widget build(BuildContext context) {
    final hits = controller.searchResults;
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: SR.border),
        boxShadow: SR.popoverShadow,
      ),
      child: controller.searchNoResults
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              child: Text(
                'Nothing matched. Try a building name, or paste coordinates.',
                style: sans(12, color: SR.muted),
              ),
            )
          : ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: hits.length,
              itemBuilder: (context, index) {
                final hit = hits[index];
                return Hoverable(
                  builder: (context, hovered) => GestureDetector(
                    onTap: () => controller.pickSearchHit(hit),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: hovered ? SR.blueTint2 : SR.surface,
                        border: Border(
                          bottom: BorderSide(color: SR.dividerSoft),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: SR.blueTint,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Icon(hit.icon, size: 12, color: SR.blue),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  hit.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: sans(12, w: 500),
                                ),
                                Text(
                                  hit.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: mono(10.5, color: SR.muted),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            hit.kind,
                            style: mono(
                              9.5,
                              tracking: .04,
                              color: SR.mutedLight,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
