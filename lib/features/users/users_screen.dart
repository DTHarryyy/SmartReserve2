import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/account.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/record_table.dart';
import '../../widgets/sr_controls.dart';
import 'invite_dialog.dart';
import 'user_detail_dialog.dart';

class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  final _search = TextEditingController();
  String _query = '';
  String _role = 'All roles';
  String _status = 'All statuses';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static List<ColSpec> _columns(bool external) => <ColSpec>[
    const ColSpec('PERSON', flex: 4),
    const ColSpec('ROLE', flex: 3, hide: ColumnHide.small),
    ColSpec(
      external ? 'ACCESS' : 'VERIFICATION',
      width: 120,
      hide: ColumnHide.small,
    ),
    const ColSpec('RESERVATIONS', width: 96, hide: ColumnHide.medium),
    ColSpec(
      external ? 'LAST RESERVATION' : 'LAST ACTIVE',
      width: 112,
      hide: ColumnHide.medium,
    ),
    const ColSpec('STATUS', width: 96, alignRight: true),
  ];

  static const _roleFilters = [
    'All roles',
    'User',
    'Internal admin',
    'External admin',
  ];

  static const _statusFilters = [
    'All statuses',
    'Active',
    'Suspended',
    'Invited',
  ];

  List<Account> _visible(AppState state) {
    final q = _query.trim().toLowerCase();
    return [
      for (final a in state.accounts)
        if ((_role == 'All roles' || a.role.label == _role) &&
            (_status == 'All statuses' || a.status.label == _status) &&
            (q.isEmpty ||
                a.name.toLowerCase().contains(q) ||
                a.email.toLowerCase().contains(q) ||
                a.idNumber.toLowerCase().contains(q)))
          a,
    ]..sort((a, b) {
      if (a.isSelf != b.isSelf) return a.isSelf ? -1 : 1;
      final aTime = a.lastActiveAt;
      final bTime = b.lastActiveAt;
      if (aTime != null && bTime != null) return bTime.compareTo(aTime);
      if (aTime != null) return -1;
      if (bTime != null) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final rows = _visible(state);
    final columns = _columns(state.isExternalAdmin);
    final width = MediaQuery.sizeOf(context).width;
    final stacked = width < SR.tabletMin;

    return Scrollbar(
      child: SingleChildScrollView(
        padding: SR.pageInsets(width, top: stacked ? 14 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (stacked)
              _mobileFilters(rows.length, state.accounts.length)
            else
              FilterBar(
                count: '${rows.length} of ${state.accounts.length}',
                trailing: state.isInternalAdmin
                    ? [
                        SrButton(
                          label: '＋ Invite administrator',
                          kind: SrButtonKind.primary,
                          onPressed: () => showInviteDialog(context, state),
                        ),
                      ]
                    : const [],
                children: [
                  FilterSearch(
                    key: const Key('users-search'),
                    controller: _search,
                    placeholder: 'Name, email or ID number',
                    width: 280,
                    onChanged: (v) => setState(() => _query = v),
                  ),
                  if (state.isInternalAdmin)
                    FilterSelect(
                      value: _role,
                      items: _roleFilters,
                      semanticLabel: 'Filter by role',
                      onChanged: (v) => setState(() => _role = v),
                    ),
                  FilterSelect(
                    value: _status,
                    items: _statusFilters,
                    semanticLabel: 'Filter by status',
                    onChanged: (v) => setState(() => _status = v),
                  ),
                ],
              ),
            RecordTable(
              columns: columns,
              footerNote: state.isExternalAdmin
                  ? 'Only paying clients with released reservations are shown. Campus verification and administrator details are excluded.'
                  : 'Only internal admins can invite. Invitation links are '
                        'single-use and expire automatically; the last internal '
                        'admin cannot be removed or demoted.',
              children: state.accountsLoading && state.accounts.isEmpty
                  ? [
                      for (var i = 0; i < 4; i++)
                        SkeletonRow(
                          columns: columns,
                          leadWidth: .45 + (i * .08),
                        ),
                    ]
                  : state.accountsError != null && state.accounts.isEmpty
                  ? [
                      ListEmptyState(
                        glyph: '!',
                        title: 'Accounts could not load',
                        body: state.accountsError!,
                        action: SrButton(
                          label: 'Try again',
                          onPressed: state.refreshAccounts,
                        ),
                      ),
                    ]
                  : rows.isEmpty
                  ? [
                      ListEmptyState(
                        glyph: '⌕',
                        title: 'No accounts match',
                        body: 'Clear a filter or search a different name.',
                        action: SrButton(
                          label: 'Clear filters',
                          onPressed: () => setState(() {
                            _query = '';
                            _search.clear();
                            _role = 'All roles';
                            _status = 'All statuses';
                          }),
                        ),
                      ),
                    ]
                  : [
                      for (final account in rows)
                        _row(context, state, account, columns),
                    ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileFilters(int visible, int total) => Padding(
    key: const Key('users-mobile-filters'),
    padding: const EdgeInsets.only(bottom: 14),
    child: LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            key: const Key('users-filter-row'),
            children: [
              Expanded(
                child: SizedBox(
                  key: const Key('users-search'),
                  height: 44,
                  child: FilterSearch(
                    controller: _search,
                    placeholder: 'Name, email or ID number',
                    width: double.infinity,
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                key: const Key('users-filter-button'),
                height: 44,
                child: CompactFilterButton(
                  activeCount:
                      (_role == 'All roles' ? 0 : 1) +
                      (_status == 'All statuses' ? 0 : 1),
                  onPressed: _showMobileFilters,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '$visible of $total',
              style: mono(10.5, color: SR.muted),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _showMobileFilters() => showSrFilterSheet(
    context,
    title: 'Filter users',
    child: StatefulBuilder(
      builder: (context, sheetSetState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (AppScope.read(context).isInternalAdmin) ...[
            const SrLabel('Role'),
            FilterSelect(
              key: const Key('users-role-filter'),
              value: _role,
              items: _roleFilters,
              semanticLabel: 'Filter by role',
              onChanged: (value) {
                setState(() => _role = value);
                sheetSetState(() {});
              },
            ),
            const SizedBox(height: 14),
          ],
          const SrLabel('Status'),
          FilterSelect(
            key: const Key('users-status-filter'),
            value: _status,
            items: _statusFilters,
            semanticLabel: 'Filter by status',
            onChanged: (value) {
              setState(() => _status = value);
              sheetSetState(() {});
            },
          ),
          const SizedBox(height: 18),
          SrButton(
            label: 'Clear filters',
            expand: true,
            onPressed: () {
              setState(() {
                _role = 'All roles';
                _status = 'All statuses';
              });
              sheetSetState(() {});
            },
          ),
          const SizedBox(height: 8),
          SrButton(
            label: 'Show users',
            kind: SrButtonKind.primary,
            expand: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    ),
  );

  Widget _row(
    BuildContext context,
    AppState state,
    Account account,
    List<ColSpec> columns,
  ) => RecordRow(
    columns: columns,
    vertical: 12,
    compactChild: _UserCompactCard(
      key: ValueKey('user-compact-${account.id}'),
      account: account,
      external: state.isExternalAdmin,
    ),
    onTap: state.isExternalAdmin
        ? null
        : () => showUserDetail(context, state: state, account: account),
    cells: [
      Row(
        children: [
          Initials(text: account.initials, size: 30, fontSize: 10),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        account.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sans(12.5, w: 500),
                      ),
                    ),
                    if (account.role.isAdmin) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: SR.ink,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'ADMIN',
                          style: mono(
                            8,
                            w: 600,
                            tracking: .04,
                            color: SR.surface,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  account.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono(10.5, color: SR.muted),
                ),
              ],
            ),
          ),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            account.role.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sans(12, color: SR.ink3),
          ),
          Text(
            account.unit,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sans(10, color: SR.muted),
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: state.isExternalAdmin
            ? const SrPill(
                label: 'Paying client',
                background: SR.amberTint,
                foreground: SR.amber,
              )
            : SrPill(
                label: account.verification.label,
                background: account.verification.background,
                foreground: account.verification.foreground,
              ),
      ),
      Text(
        account.activityMetricsAvailable ? '${account.reservations}' : '—',
        style: mono(12, color: SR.ink3),
      ),
      Text(
        account.lastActive,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sans(11, color: SR.muted),
      ),
      SrPill(
        label: account.status.label,
        background: account.status.background,
        foreground: account.status.foreground,
      ),
    ],
  );
}

class _UserCompactCard extends StatelessWidget {
  const _UserCompactCard({
    super.key,
    required this.account,
    required this.external,
  });

  final Account account;
  final bool external;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Initials(text: account.initials, size: 44, fontSize: 12),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(account.name, style: sans(13.5, w: 600, height: 1.3)),
                const SizedBox(height: 2),
                Text(
                  account.email,
                  style: mono(10.5, height: 1.45, color: SR.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SrPill(
            label: account.status.label,
            background: account.status.background,
            foreground: account.status.foreground,
          ),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _UserFact(label: 'Role', value: account.role.label),
          _UserFact(
            label: external ? 'Access' : 'Verification',
            value: external ? 'Paying client' : account.verification.label,
          ),
          _UserFact(
            label: 'Reservations',
            value: account.activityMetricsAvailable
                ? '${account.reservations}'
                : '—',
          ),
          _UserFact(label: 'Last active', value: account.lastActive),
        ],
      ),
    ],
  );
}

class _UserFact extends StatelessWidget {
  const _UserFact({required this.label, required this.value});

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
    child: Text('$label: $value', style: sans(10.5, color: SR.ink3)),
  );
}
