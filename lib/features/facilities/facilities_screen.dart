import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/facility.dart';
import '../../model/facility_photo.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/rating_display.dart';
import '../../widgets/record_table.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';
import 'facility_detail_dialog.dart';

import '../../theme/sr_theme.dart';

enum FacilityFilter {
  all('All'),
  active('Available'),
  needsPin('Needs a pin'),
  draft('Draft');

  const FacilityFilter(this.label);

  final String label;

  bool matches(Facility f) => switch (this) {
    FacilityFilter.all => true,
    FacilityFilter.active => f.state == FacilityState.active,
    FacilityFilter.needsPin => f.pinConfidence != PinConfidence.verified,
    FacilityFilter.draft => f.state == FacilityState.draft,
  };
}

class FacilitiesScreen extends StatefulWidget {
  const FacilitiesScreen({super.key, required this.onEdit});

  final void Function(Facility? facility) onEdit;

  @override
  State<FacilitiesScreen> createState() => _FacilitiesScreenState();
}

class _FacilitiesScreenState extends State<FacilitiesScreen> {
  final _search = TextEditingController();
  String _query = '';
  FacilityFilter _filter = FacilityFilter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static const _columns = <ColSpec>[
    ColSpec('FACILITY', flex: 4),
    ColSpec('BUILDING', flex: 3, hide: ColumnHide.small),
    ColSpec('CATEGORY', flex: 2, hide: ColumnHide.medium),
    ColSpec('RATING', width: 96, hide: ColumnHide.medium),
    ColSpec('CAP.', width: 48, hide: ColumnHide.small),
    ColSpec('PIN', width: 92, hide: ColumnHide.medium),
    ColSpec('STATUS', width: 104),
    ColSpec('ACTIONS', width: 66, alignRight: true),
  ];

  List<Facility> _visible(AppState state) {
    final q = _query.trim().toLowerCase();
    return [
      for (final f in state.facilities)
        if (_filter.matches(f) &&
            (q.isEmpty ||
                f.name.toLowerCase().contains(q) ||
                f.room.toLowerCase().contains(q) ||
                f.building.toLowerCase().contains(q) ||
                f.category.toLowerCase().contains(q)))
          f,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final rows = _visible(state);
    final width = MediaQuery.sizeOf(context).width;
    final stacked = width < SR.tabletMin;

    return SrScrollView(
      padding: SR.pageInsets(width, top: stacked ? 14 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SrPageHeader(
            title: 'Facilities',
            description: state.facilitiesLoading
                ? null
                : '${rows.length} of ${state.facilities.length} shown',
          ),
          const SizedBox(height: SR.space16),
          SrSearchField(
            controller: _search,
            placeholder: 'Search facilities',
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: SR.space12),
          SrTabs(
            scrollable: stacked,
            items: [
              for (final filter in FacilityFilter.values)
                SrTabItem(
                  label: filter.label,
                  count: state.facilities.where(filter.matches).length,
                ),
            ],
            selectedIndex: _filter.index,
            onSelect: (i) => setState(() => _filter = FacilityFilter.values[i]),
          ),
          const SizedBox(height: SR.space16),
          if (state.facilitiesLoading)
            RecordTable(
              columns: _columns,
              children: [
                for (var i = 0; i < 6; i++)
                  SkeletonRow(
                    columns: _columns,
                    leadWidth: [.7, .5, .8, .45, .65, .55][i],
                  ),
              ],
            )
          else if (state.facilitiesError != null)
            RecordTable(columns: _columns, children: [_error(state)])
          else if (rows.isEmpty)
            RecordTable(columns: _columns, children: [_empty(state)])
          else
            RecordTable(
              columns: _columns,
              footerNote:
                  'Every row is a record students navigate by. A pin that is '
                  'wrong here sends someone to the wrong building.',
              children: [
                for (final facility in rows) _row(context, state, facility),
              ],
            ),
        ],
      ),
    );
  }

  Widget _empty(AppState state) {
    final filtered = state.facilities.isNotEmpty;
    return ListEmptyState(
      icon: filtered ? Icons.search_off_rounded : Icons.apartment_rounded,
      title: filtered ? 'Nothing matches' : 'No facilities yet',
      body: filtered
          ? 'Clear the search or pick a different filter.'
          : 'Add your first facility and pin it on the campus map. Students '
                'and staff use that pin for directions, so accuracy matters '
                'more than speed.',
      action: filtered
          ? SrButton(
              label: 'Clear filters',
              onPressed: () => setState(() {
                _query = '';
                _search.clear();
                _filter = FacilityFilter.all;
              }),
            )
          : state.isAdmin
          ? SrButton(
              label: 'Add the first facility',
              kind: SrButtonKind.primary,
              onPressed: () {
                widget.onEdit(null);
              },
            )
          : null,
    );
  }

  Widget _error(AppState state) => ListEmptyState(
    icon: Icons.error_outline_rounded,
    title: 'Facilities could not be loaded',
    body: state.facilitiesError ?? 'Check the connection and try again.',
    action: SrButton(
      label: 'Retry',
      kind: SrButtonKind.primary,
      onPressed: state.refreshFacilities,
    ),
  );

  Widget _row(BuildContext context, AppState state, Facility facility) =>
      RecordRow(
        columns: _columns,
        compactChild: _FacilityCompactCard(
          key: ValueKey('facility-compact-${facility.id}'),
          facility: facility,
          canEdit: facility.canManage,
          onEdit: () => widget.onEdit(facility),
          onDelete: () =>
              confirmDeleteFacility(context, state: state, facility: facility),
        ),
        onTap: () => showFacilityDetail(
          context,
          state: state,
          facility: facility,
          onEdit: () => widget.onEdit(facility),
          onDelete: () =>
              confirmDeleteFacility(context, state: state, facility: facility),
        ),
        cells: [
          Row(
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: facility.coverPhoto == null
                      ? ColoredBox(color: context.srColors.hairline)
                      : FacilityPhotoImage(photo: facility.coverPhoto!),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      facility.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(12.5, w: 500),
                    ),
                    Text(
                      facility.room,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono(10.5, color: context.srColors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Text(
            facility.building,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sans(12, color: context.srColors.ink3),
          ),
          Text(
            facility.category,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sans(12, color: context.srColors.ink3),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: SrRatingStars(
              average: facility.ratingAverage,
              count: facility.ratingCount,
              dense: true,
              compact: true,
              showCount: false,
            ),
          ),
          Text(
            '${facility.capacity}',
            style: mono(12, color: context.srColors.ink3),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: SrStatusChip(
              label: facility.pinConfidence.label,
              tone: facility.pinConfidence.tone,
              dot: true,
              dense: true,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: SrStatusChip(
              label: facility.state.label,
              tone: facility.state.tone,
            ),
          ),
          if (facility.canManage)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SrIconButton(
                  icon: Icons.edit_outlined,
                  tooltip: 'Edit ${facility.name}',
                  size: 28,
                  fontSize: 11,
                  radius: 7,
                  onPressed: () => widget.onEdit(facility),
                ),
                const SizedBox(width: 5),
                SrIconButton(
                  icon: Icons.delete_outline_rounded,
                  tooltip: 'Delete ${facility.name}',
                  size: 28,
                  fontSize: 11,
                  radius: 7,
                  foreground: context.srColors.red,
                  hoverForeground: context.srColors.red,
                  onPressed: () => confirmDeleteFacility(
                    context,
                    state: state,
                    facility: facility,
                  ),
                ),
              ],
            )
          else
            const SizedBox.shrink(),
        ],
      );
}

class _FacilityCompactCard extends StatelessWidget {
  const _FacilityCompactCard({
    super.key,
    required this.facility,
    required this.canEdit,
    required this.onEdit,
    required this.onDelete,
  });

  final Facility facility;
  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: facility.coverPhoto == null
                  ? ColoredBox(color: context.srColors.hairline)
                  : FacilityPhotoImage(photo: facility.coverPhoto!),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(facility.name, style: sans(13.5, w: 600, height: 1.3)),
                const SizedBox(height: 2),
                Text(
                  '${facility.room} · ${facility.building}',
                  style: sans(11.5, height: 1.45, color: context.srColors.ink4),
                ),
              ],
            ),
          ),
          if (canEdit)
            PopupMenuButton<String>(
              tooltip: 'Actions for ${facility.name}',
              onSelected: (value) => value == 'edit' ? onEdit() : onDelete(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit facility')),
                PopupMenuItem(value: 'delete', child: Text('Delete facility')),
              ],
              icon: Icon(Icons.more_vert_rounded, color: context.srColors.ink4),
            ),
        ],
      ),
      const SizedBox(height: SR.space12),
      Wrap(
        spacing: SR.space8,
        runSpacing: SR.space8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SrStatusChip(label: facility.state.label, tone: facility.state.tone),
          SrFactChip(label: 'Capacity', value: '${facility.capacity}'),
          SrFactChip(label: 'Category', value: facility.category),
          if (facility.hasRatings)
            SrRatingStars(
              average: facility.ratingAverage,
              count: facility.ratingCount,
              dense: true,
              compact: true,
            ),
        ],
      ),
    ],
  );
}
