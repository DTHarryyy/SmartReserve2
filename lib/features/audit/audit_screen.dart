import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/audit_entry.dart';
import '../../model/notice.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/sr_controls.dart';

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
  bool _materialOnly = false;
  final Set<String> _expanded = {};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<AuditEntry> _visible(AppState state) {
    final q = _query.trim().toLowerCase();
    return [
      for (final e in state.audit)
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

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final rows = _visible(state);
    final stacked = MediaQuery.sizeOf(context).width < SR.tabletMin;
    final actors = <String>{'All people', for (final e in state.audit) e.actor};

    return Scrollbar(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          stacked ? 14 : 24,
          stacked ? 14 : 20,
          stacked ? 14 : 24,
          40,
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 940),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilterBar(
                  count: '${rows.length} of ${state.audit.length}',
                  trailing: [
                    SrButton(
                      label: 'Export CSV',
                      onPressed: () => _export(state, rows),
                    ),
                  ],
                  children: [
                    FilterSearch(
                      controller: _search,
                      placeholder: 'Search people, records or reasons',
                      width: stacked ? 220 : 280,
                      onChanged: (v) => setState(() => _query = v),
                    ),
                    FilterSelect(
                      value: _actor,
                      items: actors.toList(),
                      semanticLabel: 'Filter by person',
                      onChanged: (v) => setState(() => _actor = v),
                    ),
                    FilterSelect(
                      value: _kind,
                      items: const [
                        'All records',
                        'FACILITY',
                        'RESERVATION',
                        'ACCOUNT',
                      ],
                      semanticLabel: 'Filter by record type',
                      onChanged: (v) => setState(() => _kind = v),
                    ),
                    FilterPill(
                      label: 'Material changes only',
                      selected: _materialOnly,
                      onTap: () =>
                          setState(() => _materialOnly = !_materialOnly),
                    ),
                  ],
                ),

                Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: SR.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: SR.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: rows.isEmpty
                        ? [_empty()]
                        : [
                            for (final entry in rows)
                              _EntryRow(
                                entry: entry,
                                expanded: _expanded.contains(entry.id),
                                onToggle: () => setState(() {
                                  if (!_expanded.remove(entry.id)) {
                                    _expanded.add(entry.id);
                                  }
                                }),
                                onRevert: () => state.revertAudit(entry),
                              ),
                          ],
                  ),
                ),

                const SizedBox(height: 12),
                Text(
                  'Append-only: reverting writes a new entry and keeps the '
                  'original. Full detail is kept for 24 months, then '
                  'summarised. Account and role entries are visible to '
                  'internal admins only, and an export records who exported '
                  'it.',
                  style: sans(11, height: 1.6, color: SR.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _export(AppState state, List<AuditEntry> rows) async {
    final csv = state.exportAuditCsv(rows);
    await Clipboard.setData(ClipboardData(text: csv));
    state.showToast(
      ToastMessage(
        '${rows.length} entries copied as CSV, signed with your name. The '
        'export is itself logged.',
        tone: AdvisoryTone.info,
      ),
    );
  }

  Widget _empty() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 48),
    child: Column(
      children: [
        Text('No entries match', style: sans(13.5, w: 600)),
        const SizedBox(height: 5),
        Text(
          'Clear a filter, or turn off “material changes only”.',
          style: sans(12, height: 1.6, color: SR.ink4),
        ),
      ],
    ),
  );
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
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
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: SR.divider)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Hoverable(
          builder: (context, hovered) => GestureDetector(
            onTap: onToggle,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              color: hovered ? SR.surfaceSubtle : SR.surface,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: SR.hairline,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      entry.initials,
                      style: mono(9.5, w: 600, color: SR.ink3),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: entry.actor,
                                style: sans(12.5, w: 600, height: 1.55),
                              ),
                              TextSpan(text: ' ${entry.action} '),
                              TextSpan(
                                text: entry.target,
                                style: sans(12.5, w: 600, height: 1.55),
                              ),
                            ],
                          ),
                          style: sans(12.5, height: 1.55, color: SR.ink2),
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
                            if (entry.material)
                              const SrPill(
                                label: 'MATERIAL',
                                background: SR.redTint,
                                foreground: Color(0xFF912018),
                                monospace: true,
                                fontSize: 8.5,
                              ),
                            Text(
                              '${entry.when} · ${entry.absolute}',
                              style: mono(10.5, color: SR.muted),
                            ),
                            Text(
                              entry.actorRole,
                              style: sans(10.5, color: SR.mutedLight),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
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
              ),
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(55, 0, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: SR.surfaceSubtle,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: SR.hairline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in entry.diff)
                        Text(
                          line,
                          style: mono(
                            11.5,
                            w: 500,
                            height: 1.7,
                            color: SR.ink2,
                          ),
                        ),
                    ],
                  ),
                ),
                if (entry.reason.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Reason: “${entry.reason}”',
                    style: sans(11.5, height: 1.6, color: SR.ink4),
                  ),
                ],
                if (entry.revertable) ...[
                  const SizedBox(height: 10),
                  SrButton(
                    label: '↺ Revert this change',
                    dense: true,
                    fontSize: 11,
                    onPressed: onRevert,
                  ),
                ],
              ],
            ),
          ),
      ],
    ),
  );
}
