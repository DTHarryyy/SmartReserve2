import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/facility.dart';
import '../../model/facility_photo.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/queue_shell.dart';
import '../../widgets/record_table.dart';
import '../../widgets/sr_controls.dart';
import 'facility_detail_dialog.dart';

enum FacilityFilter {
  all('All'),
  active('Active'),
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

    return Scrollbar(
      child: SingleChildScrollView(
        padding: SR.pageInsets(width, top: stacked ? 14 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilterBar(
              count: state.facilitiesLoading
                  ? null
                  : '${rows.length} of ${state.facilities.length}',
              children: [
                FilterSearch(
                  controller: _search,
                  placeholder: 'Search facilities',
                  width: stacked ? double.infinity : 300,
                  onChanged: (v) => setState(() => _query = v),
                ),
                for (final filter in FacilityFilter.values)
                  QueueTab(
                    label: filter.label,
                    count: state.facilities.where(filter.matches).length,
                    selected: _filter == filter,
                    onTap: () => setState(() => _filter = filter),
                  ),
              ],
            ),
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
      ),
    );
  }

  Widget _empty(AppState state) {
    final filtered = state.facilities.isNotEmpty;
    return ListEmptyState(
      glyph: '⌖',
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
          : state.isInternalAdmin
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
    glyph: '!',
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
          canEdit: state.isInternalAdmin,
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
                      ? const ColoredBox(color: SR.hairline)
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
                      style: mono(10.5, color: SR.muted),
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
            style: sans(12, color: SR.ink3),
          ),
          Text(
            facility.category,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sans(12, color: SR.ink3),
          ),
          Text('${facility.capacity}', style: mono(12, color: SR.ink3)),
          Text(
            facility.pinConfidence.label,
            maxLines: 1,
            style: mono(10, w: 500, color: facility.pinConfidence.color),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: SrPill(
              label: facility.state.label,
              background: facility.state.background,
              foreground: facility.state.foreground,
            ),
          ),
          if (state.isInternalAdmin)
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
                  foreground: SR.red,
                  hoverForeground: SR.red,
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
                  ? const ColoredBox(color: SR.hairline)
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
                  style: sans(11.5, height: 1.45, color: SR.ink4),
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
              icon: const Icon(Icons.more_vert_rounded, color: SR.ink4),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SrPill(
            label: facility.state.label,
            background: facility.state.background,
            foreground: facility.state.foreground,
          ),
          _CompactFact(label: 'Capacity', value: '${facility.capacity}'),
          _CompactFact(label: 'Category', value: facility.category),
        ],
      ),
    ],
  );
}

class _CompactFact extends StatelessWidget {
  const _CompactFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: SR.surfaceSubtle,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: SR.hairline),
    ),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: sans(10.5, color: SR.muted),
          ),
          TextSpan(
            text: value,
            style: sans(10.5, w: 500, color: SR.ink3),
          ),
        ],
      ),
    ),
  );
}
