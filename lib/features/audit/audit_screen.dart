import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
import '../../model/audit_change.dart';
import '../../model/audit_entry.dart';
import '../../model/notice.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/record_table.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';

const _kinds = ['All records', 'FACILITY', 'RESERVATION', 'ACCOUNT', 'SYSTEM'];

const _columns = [
  ColSpec('WHEN', width: 106),
  ColSpec('PERSON', flex: 3),
  ColSpec('ACTION', flex: 5),
  ColSpec('TYPE', width: 100, hide: ColumnHide.medium),
  ColSpec('', width: 22, alignRight: true),
];

enum _AuditRange {
  today('Today'),
  week('Last 7 days'),
  month('Last 30 days'),
  quarter('Last 90 days'),
  all('All time');

  const _AuditRange(this.label);
  final String label;

  DateTime? from(DateTime now) => switch (this) {
    _AuditRange.today => DateTime(now.year, now.month, now.day),
    _AuditRange.week => now.subtract(const Duration(days: 7)),
    _AuditRange.month => now.subtract(const Duration(days: 30)),
    _AuditRange.quarter => now.subtract(const Duration(days: 90)),
    _AuditRange.all => null,
  };

  static _AuditRange fromLabel(String label) =>
      values.firstWhere((r) => r.label == label, orElse: () => _AuditRange.all);
}

class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  final _search = TextEditingController();
  String _query = '';
  String _actor = 'All people';
  String _kind = 'All records';
  _AuditRange _range = _AuditRange.all;
  bool _materialOnly = false;
  bool _showRetention = false;
  final Set<String> _expanded = {};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<AuditEntry> _visible(List<AuditEntry> entries) {
    final q = _query.trim().toLowerCase();
    return [
      for (final e in entries)
        if ((_actor == 'All people' || e.actor == _actor) &&
            (_kind == 'All records' || e.kind.label == _kind) &&
            (!_materialOnly || e.material) &&
            (q.isEmpty ||
                e.actor.toLowerCase().contains(q) ||
                e.target.toLowerCase().contains(q) ||
                e.action.toLowerCase().contains(q) ||
                e.reason.toLowerCase().contains(q) ||
                e.diff.any((d) => d.toLowerCase().contains(q))))
          e,
    ];
  }

  bool get _hasActiveFilter =>
      _query.isNotEmpty ||
      _actor != 'All people' ||
      _kind != 'All records' ||
      _range != _AuditRange.all ||
      _materialOnly;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final isDemo = state.backend == null;
    final source = isDemo ? state.audit : state.remoteAudit;
    final rows = isDemo ? _visible(source) : source;
    final width = MediaQuery.sizeOf(context).width;
    final stacked = width < SR.tabletMin;
    final total = isDemo ? state.audit.length : state.auditTotal;
    final actors = <String>{
      'All people',
      ...state.auditActors,
      for (final e in source) e.actor,
    };

    return SrScrollView(
      padding: SR.pageInsets(width, top: stacked ? 14 : 20),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (SR.isCompact(width))
                _compactFilters(state, actors.toList(), rows.length, total)
              else
                _desktopToolbar(state, actors.toList(), rows.length, total),

              if (state.auditLoading && rows.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: LinearProgressIndicator(),
                ),
              if (state.auditError case final error?)
                Padding(
                  padding: const EdgeInsets.only(bottom: SR.space8 + 2),
                  child: Text(error, style: SrType.bodySm(color: SR.red)),
                ),

              RecordTable(
                columns: _columns,
                children: state.auditLoading && rows.isEmpty
                    ? [
                        for (final leadWidth in const [.6, .45, .7, .5, .55])
                          SkeletonRow(columns: _columns, leadWidth: leadWidth),
                      ]
                    : rows.isEmpty
                    ? [
                        ListEmptyState(
                          icon: Icons.filter_alt_off_rounded,
                          title: 'No entries match',
                          body:
                              'Clear a filter, or turn off "material '
                              'changes only".',
                          action: _hasActiveFilter
                              ? SrButton(
                                  label: 'Clear filters',
                                  onPressed: () => _clearAll(state),
                                )
                              : null,
                        ),
                      ]
                    : [
                        for (final entry in rows)
                          _AuditRow(
                            key: ValueKey(entry.id),
                            entry: entry,
                            expanded: _expanded.contains(entry.id),
                            onToggle: () => _toggle(entry.id),
                            onRevert: () => state.revertAudit(entry),
                          ),
                      ],
              ),

              if (state.backend != null && rows.length < state.auditTotal)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SrButton(
                    label: state.auditLoadingMore ? 'Loading…' : 'Load more',
                    onPressed: state.auditLoadingMore
                        ? null
                        : state.loadMoreAudit,
                  ),
                ),

              const SizedBox(height: 12),
              _retentionDisclosure(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _desktopToolbar(
    AppState state,
    List<String> actors,
    int visible,
    int total,
  ) => Container(
    margin: const EdgeInsets.only(bottom: SR.space16),
    padding: const EdgeInsets.symmetric(
      horizontal: SR.space16,
      vertical: SR.space12,
    ),
    decoration: BoxDecoration(
      color: SR.surface,
      borderRadius: BorderRadius.circular(SR.rMd),
      border: Border.all(color: SR.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilterSearch(
                controller: _search,
                placeholder: 'Search people, records or reasons',
                width: double.infinity,
                onChanged: (v) {
                  setState(() => _query = v);
                  state.refreshAudit(
                    query: state.auditQuery.copyWith(
                      search: v,
                      resetPage: true,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: SR.space8 + 2),
            SrButton(
              label: 'Export CSV',
              icon: const Icon(
                Icons.file_download_outlined,
                size: SR.iconSm,
                color: SR.ink3,
              ),
              onPressed: () => _export(state),
            ),
          ],
        ),
        const SizedBox(height: SR.space8 + 2),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final k in _kinds)
              FilterPill(
                label: k == 'All records' ? 'All' : _titleCase(k),
                selected: _kind == k,
                onTap: () => _applyKind(state, k),
              ),
            const SizedBox(width: 2),
            FilterSelect(
              value: _actor,
              items: actors,
              width: 190,
              semanticLabel: 'Filter by person',
              onChanged: (v) => _applyActor(state, v),
            ),
            FilterSelect(
              value: _range.label,
              items: [for (final r in _AuditRange.values) r.label],
              width: 160,
              semanticLabel: 'Date range',
              onChanged: (v) => _applyRange(state, _AuditRange.fromLabel(v)),
            ),
            FilterPill(
              label: 'Material changes only',
              selected: _materialOnly,
              onTap: () => _applyMaterialOnly(state, !_materialOnly),
            ),
            if (_hasActiveFilter)
              Hoverable(
                builder: (context, hovered) => GestureDetector(
                  onTap: () => _clearAll(state),
                  child: Text(
                    'Clear all',
                    style: sans(
                      11.5,
                      w: 500,
                      color: hovered ? SR.ink3 : SR.muted,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            Text('$visible of $total', style: mono(10.5, color: SR.muted)),
          ],
        ),
      ],
    ),
  );

  Widget _compactFilters(
    AppState state,
    List<String> actors,
    int visible,
    int total,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 44,
                child: FilterSearch(
                  controller: _search,
                  placeholder: 'Search people, records or reasons',
                  width: double.infinity,
                  onChanged: (value) {
                    setState(() => _query = value);
                    state.refreshAudit(
                      query: state.auditQuery.copyWith(
                        search: value,
                        resetPage: true,
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            CompactFilterButton(
              activeCount:
                  (_actor == 'All people' ? 0 : 1) +
                  (_kind == 'All records' ? 0 : 1) +
                  (_range == _AuditRange.all ? 0 : 1) +
                  (_materialOnly ? 1 : 0),
              onPressed: () => _showCompactFilters(state, actors),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: Text('$visible of $total', style: mono(10.5, color: SR.muted)),
        ),
      ],
    ),
  );

  Future<void> _showCompactFilters(AppState state, List<String> actors) =>
      showSrFilterSheet(
        context,
        title: 'Filter audit log',
        child: StatefulBuilder(
          builder: (context, sheetSetState) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SrLabel('Person'),
              FilterSelect(
                value: _actor,
                items: actors,
                semanticLabel: 'Filter by person',
                onChanged: (value) {
                  _applyActor(state, value);
                  sheetSetState(() {});
                },
              ),
              const SizedBox(height: 14),
              const SrLabel('Record type'),
              FilterSelect(
                value: _kind,
                items: _kinds,
                semanticLabel: 'Filter by record type',
                onChanged: (value) {
                  _applyKind(state, value);
                  sheetSetState(() {});
                },
              ),
              const SizedBox(height: 14),
              const SrLabel('Date range'),
              FilterSelect(
                value: _range.label,
                items: [for (final r in _AuditRange.values) r.label],
                semanticLabel: 'Date range',
                onChanged: (value) {
                  _applyRange(state, _AuditRange.fromLabel(value));
                  sheetSetState(() {});
                },
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(child: Text('Material changes only')),
                  SrToggle(
                    value: _materialOnly,
                    label: 'Material changes only',
                    onChanged: (value) {
                      _applyMaterialOnly(state, value);
                      sheetSetState(() {});
                    },
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: SrButton(
                      label: 'Clear filters',
                      onPressed: () {
                        _clearAll(state);
                        sheetSetState(() {});
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SrButton(
                      label: 'Show entries',
                      kind: SrButtonKind.primary,
                      expand: true,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  void _applyKind(AppState state, String kind) {
    setState(() => _kind = kind);
    state.refreshAudit(
      query: state.auditQuery.copyWith(
        entityType: kind == 'All records' ? null : kind.toLowerCase(),
        clearEntityType: kind == 'All records',
        resetPage: true,
      ),
    );
  }

  void _applyActor(AppState state, String actor) {
    setState(() => _actor = actor);
    state.refreshAudit(
      query: state.auditQuery.copyWith(
        actor: actor == 'All people' ? null : actor,
        clearActor: actor == 'All people',
        resetPage: true,
      ),
    );
  }

  void _applyRange(AppState state, _AuditRange range) {
    setState(() => _range = range);
    final from = range.from(DateTime.now());
    state.refreshAudit(
      query: state.auditQuery.copyWith(
        from: from,
        clearFrom: from == null,
        resetPage: true,
      ),
    );
  }

  void _applyMaterialOnly(AppState state, bool value) {
    setState(() => _materialOnly = value);
    state.refreshAudit(
      query: state.auditQuery.copyWith(materialOnly: value, resetPage: true),
    );
  }

  void _clearAll(AppState state) {
    setState(() {
      _query = '';
      _search.clear();
      _actor = 'All people';
      _kind = 'All records';
      _range = _AuditRange.all;
      _materialOnly = false;
    });
    state.refreshAudit(query: const AuditQuery());
  }

  void _toggle(String id) => setState(() {
    if (!_expanded.remove(id)) _expanded.add(id);
  });

  Future<void> _export(AppState state) async {
    final exportedRows = await state.auditExportRows();
    final csv = state.exportAuditCsv(exportedRows);
    await FileSaver.instance.saveAs(
      name: 'smartreserve-audit-log',
      bytes: Uint8List.fromList(utf8.encode(csv)),
      fileExtension: 'csv',
      mimeType: MimeType.text,
    );
    if (state.backend != null) {
      await state.backend!.recordAuditExport(
        state.auditQuery,
        exportedRows.length,
      );
    }
    state.showToast(
      ToastMessage(
        '${exportedRows.length} entries saved as CSV, signed with your name. '
        'The export is itself logged.',
        tone: AdvisoryTone.info,
      ),
    );
  }

  Widget _retentionDisclosure() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Hoverable(
        builder: (context, hovered) => GestureDetector(
          onTap: () => setState(() => _showRetention = !_showRetention),
          child: Text(
            _showRetention ? 'Hide retention & access' : 'Retention & access',
            style: sans(
              11,
              w: 500,
              color: hovered ? SR.ink3 : SR.muted,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ),
      if (_showRetention) ...[
        const SizedBox(height: 6),
        Text(
          'Append-only: reverting writes a new entry and keeps the '
          'original. Full detail is kept for 24 months, then '
          'summarised. Account and role entries are visible to '
          'internal admins only, and an export records who exported '
          'it.',
          style: sans(11, height: 1.6, color: SR.muted),
        ),
      ],
    ],
  );
}

String _titleCase(String value) =>
    value.isEmpty ? value : value[0] + value.substring(1).toLowerCase();

Widget _avatar(AuditEntry entry) => entry.isSystemActor
    ? Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: SR.hairline,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.settings_suggest_rounded,
          size: 14,
          color: SR.ink4,
        ),
      )
    : SrAvatar(initials: entry.initials, size: 30, tone: SrTone.neutral);

String _roleLabel(AuditEntry entry) =>
    entry.actorRoleValue?.label ?? entry.actorRole;

String _identityName(AuditEntry entry) => entry.isSystemActor
    ? 'System'
    : (entry.actor.isEmpty ? 'Unknown' : entry.actor);

String _identitySubtitle(AuditEntry entry) {
  if (entry.isSystemActor) return 'Automatic';
  final role = _roleLabel(entry);
  final email = entry.actorEmail;
  if (role.isEmpty) return email;
  if (email.isEmpty) return role;
  return '$role · $email';
}

Widget _personCell(AuditEntry entry) {
  final subtitle = _identitySubtitle(entry);
  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      _avatar(entry),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _identityName(entry),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sans(12.5, w: 500),
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono(10.5, color: SR.muted),
              ),
          ],
        ),
      ),
    ],
  );
}

String _clockOnly(DateTime value) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(value.hour)}:${two(value.minute)}';
}

class _AuditRow extends StatefulWidget {
  const _AuditRow({
    super.key,
    required this.entry,
    required this.expanded,
    required this.onToggle,
    required this.onRevert,
  });

  final AuditEntry entry;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onRevert;

  @override
  State<_AuditRow> createState() => _AuditRowState();
}

class _AuditRowState extends State<_AuditRow> {
  bool _showTechnical = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final viewport = MediaQuery.sizeOf(context).width;
    final compact = SR.isCompact(viewport);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: compact
            ? null
            : const Border(bottom: BorderSide(color: SR.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Hoverable(
            builder: (context, hovered) => GestureDetector(
              onTap: widget.onToggle,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                margin: compact
                    ? const EdgeInsets.only(bottom: 8)
                    : EdgeInsets.zero,
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 14 : 16,
                  vertical: compact ? 14 : 13,
                ),
                decoration: BoxDecoration(
                  color: hovered ? SR.surfaceSubtle : SR.surface,
                  borderRadius: compact ? BorderRadius.circular(12) : null,
                  border: compact
                      ? Border.all(color: hovered ? SR.primarySoft : SR.border)
                      : null,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (entry.material)
                      Container(
                        width: 3,
                        height: compact ? 52 : 28,
                        margin: const EdgeInsets.only(right: 9, top: 2),
                        decoration: BoxDecoration(
                          color: SR.amber,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    Expanded(
                      child: compact
                          ? _compactHeader(entry, widget.expanded)
                          : TableRowLayout(
                              columns: _columns,
                              viewport: viewport,
                              cells: [
                                Tooltip(
                                  message: entry.absolute,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        entry.when,
                                        style: sans(
                                          11.5,
                                          w: 500,
                                          color: SR.ink3,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        entry.createdAt != null
                                            ? _clockOnly(entry.createdAt!)
                                            : '',
                                        style: mono(10, color: SR.muted),
                                      ),
                                    ],
                                  ),
                                ),
                                _personCell(entry),
                                Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(text: '${entry.action} '),
                                      TextSpan(
                                        text: entry.target,
                                        style: sans(12.5, w: 600),
                                      ),
                                    ],
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: sans(
                                    12.5,
                                    height: 1.4,
                                    color: SR.ink2,
                                  ),
                                ),
                                SrStatusChip(
                                  label: entry.kind.label,
                                  tone: entry.kind.tone,
                                  dense: true,
                                ),
                                Icon(
                                  widget.expanded
                                      ? Icons.keyboard_arrow_up_rounded
                                      : Icons.keyboard_arrow_down_rounded,
                                  size: 16,
                                  color: SR.mutedLight,
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (widget.expanded) _detail(context, entry, compact),
        ],
      ),
    );
  }

  Widget _compactHeader(AuditEntry entry, bool expanded) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _personCell(entry),
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${entry.action} '),
                  TextSpan(text: entry.target, style: sans(12.5, w: 600)),
                ],
              ),
              style: sans(12.5, height: 1.5, color: SR.ink2),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 5,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SrPill(
                  label: entry.kind.label,
                  background: entry.kind.background,
                  foreground: entry.kind.foreground,
                  monospace: true,
                  fontSize: 8.5,
                ),
                Text(entry.when, style: mono(10.5, color: SR.muted)),
              ],
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Icon(
          expanded
              ? Icons.keyboard_arrow_up_rounded
              : Icons.keyboard_arrow_down_rounded,
          size: 16,
          color: SR.mutedLight,
        ),
      ),
    ],
  );

  Widget _detail(BuildContext context, AuditEntry entry, bool compact) {
    final hasChanges = entry.changes.isNotEmpty;
    final hasRaw =
        entry.rawBefore.isNotEmpty ||
        entry.rawAfter.isNotEmpty ||
        entry.rawDetails.isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 16 : 56, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            decoration: BoxDecoration(
              color: SR.surfaceSubtle,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: SR.hairline),
            ),
            child: hasChanges
                ? _changeGrid(entry.changes)
                : _legacyDiff(entry.diff),
          ),
          if (entry.reason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Reason: "${entry.reason}"',
              style: sans(11.5, height: 1.6, color: SR.ink4),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Recorded ${entry.absolute}',
            style: sans(10.5, color: SR.muted),
          ),
          if (hasRaw) ...[
            const SizedBox(height: 8),
            _technicalDisclosure(entry),
          ],
          if (entry.revertable) ...[
            const SizedBox(height: 10),
            SrButton(
              label: 'Revert this change',
              icon: const Icon(
                Icons.undo_rounded,
                size: SR.iconSm,
                color: SR.ink3,
              ),
              dense: true,
              fontSize: 11,
              onPressed: widget.onRevert,
            ),
          ],
        ],
      ),
    );
  }

  Widget _changeGrid(List<AuditChange> changes) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < changes.length; i++) ...[
        if (i > 0) const SizedBox(height: 8),
        _changeLine(changes[i]),
      ],
    ],
  );

  Widget _changeLine(AuditChange change) {
    if (change.isNote) {
      return Text(
        _breakable(change.note!),
        style: mono(11.5, w: 500, height: 1.6, color: SR.ink2),
      );
    }
    if (change.before == null) {
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${change.label}: ',
              style: mono(11.5, w: 600, color: SR.ink3),
            ),
            TextSpan(
              text: _breakable(change.after ?? '—'),
              style: mono(11.5, w: 500, color: SR.ink2),
            ),
          ],
        ),
      );
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(width: 132, child: Text(change.label, style: keyLabel)),
        Text(_breakable(change.before!), style: mono(11.5, color: SR.muted)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('→', style: mono(11, color: SR.mutedLight)),
        ),
        Text(
          _breakable(change.after ?? '—'),
          style: mono(11.5, w: 500, color: SR.ink2),
        ),
      ],
    );
  }

  Widget _legacyDiff(List<String> diff) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final line in diff)
        Text(
          _breakable(line),
          style: mono(11.5, w: 500, height: 1.7, color: SR.ink2),
        ),
    ],
  );

  Widget _technicalDisclosure(AuditEntry entry) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Hoverable(
        builder: (context, hovered) => GestureDetector(
          onTap: () => setState(() => _showTechnical = !_showTechnical),
          child: Text(
            _showTechnical
                ? 'Hide technical details'
                : 'Show technical details',
            style: sans(
              10.5,
              w: 500,
              color: hovered ? SR.ink3 : SR.muted,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ),
      if (_showTechnical) ...[
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: SR.ink.withValues(alpha: .03),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            _breakable(
              _prettyJson({
                if (entry.rawBefore.isNotEmpty) 'before': entry.rawBefore,
                if (entry.rawAfter.isNotEmpty) 'after': entry.rawAfter,
                if (entry.rawDetails.isNotEmpty) 'details': entry.rawDetails,
              }),
            ),
            style: mono(10, height: 1.6, color: SR.ink3),
          ),
        ),
      ],
    ],
  );
}

String _prettyJson(Map<String, dynamic> value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

final _zeroWidthSpace = String.fromCharCode(0x200B);

String _breakable(String value) => value.replaceAllMapped(
  RegExp(r'[/._:\-]'),
  (match) => '${match.group(0)}$_zeroWidthSpace',
);
