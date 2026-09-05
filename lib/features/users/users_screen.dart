import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/account.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/record_table.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';
import 'invite_dialog.dart';
import 'user_detail_dialog.dart';

import '../../theme/sr_theme.dart';

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

  bool get _hasActiveFilter =>
      _role != 'All roles' || _status != 'All statuses';

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final rows = _visible(state);
    final columns = _columns(state.isExternalAdmin);
    final width = MediaQuery.sizeOf(context).width;
    final stacked = width < SR.tabletMin;

    return SrScrollView(
      padding: SR.pageInsets(width, top: stacked ? 14 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!stacked) ...[
            SrPageHeader(
              title: state.isExternalAdmin ? 'Clients' : 'Users',
              description: '${rows.length} of ${state.accounts.length} shown',
              actions: [
                if (state.isInternalAdmin)
                  SrButton(
                    label: 'Invite administrator',
                    icon: const Icon(
                      Icons.person_add_alt_1_rounded,
                      size: SR.iconMd,
                      color: SR.onDark,
                    ),
                    kind: SrButtonKind.primary,
                    onPressed: () => showInviteDialog(context, state),
                  ),
              ],
            ),
            const SizedBox(height: SR.space16),
            _desktopToolbar(state),
          ] else
            _mobileFilters(rows.length, state.accounts.length),
          const SizedBox(height: SR.space16),
          RecordTable(
            columns: columns,
            footerNote: state.isExternalAdmin
                ? 'This shared directory includes all active guest or unverified clients with reservation or payment activity. Campus records, administrator accounts, and verification documents are excluded.'
                : 'Only internal admins can invite. Invitation links are '
                      'single-use and expire automatically; the last internal '
                      'admin cannot be removed or demoted.',
            children: state.accountsLoading && state.accounts.isEmpty
                ? [
                    for (var i = 0; i < 4; i++)
                      SkeletonRow(columns: columns, leadWidth: .45 + (i * .08)),
                  ]
                : state.accountsError != null && state.accounts.isEmpty
                ? [
                    ListEmptyState(
                      icon: Icons.error_outline_rounded,
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
                      icon: Icons.search_off_rounded,
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
    );
  }

  Widget _mobileFilters(int visible, int total) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        key: const Key('users-filter-row'),
        children: [
          Expanded(
            child: SizedBox(
              key: const Key('users-search'),
              height: 44,
              child: SrSearchField(
                controller: _search,
                placeholder: 'Name, email or ID number',
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
          '$visible of $total shown',
          style: mono(10.5, color: context.srColors.muted),
        ),
      ),
    ],
  );

  Widget _desktopToolbar(AppState state) => SrCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const Key('users-search'),
          height: 40,
          child: SrSearchField(
            controller: _search,
            placeholder: 'Name, email or ID number',
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        const SizedBox(height: SR.space12),
        Wrap(
          spacing: SR.space8,
          runSpacing: SR.space8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (state.isInternalAdmin)
              FilterSelect(
                value: _role,
                items: _roleFilters,
                width: 170,
                semanticLabel: 'Filter by role',
                onChanged: (v) => setState(() => _role = v),
              ),
            FilterSelect(
              value: _status,
              items: _statusFilters,
              width: 170,
              semanticLabel: 'Filter by status',
              onChanged: (v) => setState(() => _status = v),
            ),
            if (_hasActiveFilter)
              Hoverable(
                builder: (context, hovered) => GestureDetector(
                  onTap: () => setState(() {
                    _role = 'All roles';
                    _status = 'All statuses';
                  }),
                  child: Text(
                    'Clear filters',
                    style: sans(
                      11.5,
                      w: 500,
                      color: hovered
                          ? context.srColors.ink3
                          : context.srColors.muted,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
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
                      const SizedBox(width: SR.space6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: SR.space6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: context.srColors.primaryTint,
                          borderRadius: BorderRadius.circular(SR.rXs),
                          border: Border.all(
                            color: context.srColors.primaryLine,
                          ),
                        ),
                        child: Text(
                          'ADMIN',
                          style: mono(
                            8,
                            w: 600,
                            tracking: .04,
                            color: context.srColors.primaryDeep,
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
                  style: mono(10.5, color: context.srColors.muted),
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
            style: sans(12, color: context.srColors.ink3),
          ),
          Text(
            account.unit,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sans(10, color: context.srColors.muted),
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: state.isExternalAdmin
            ? const SrStatusChip(label: 'Paying client', tone: SrTone.warning)
            : SrStatusChip(
                label: account.verification.label,
                tone: account.verification.tone,
              ),
      ),
      Text(
        account.activityMetricsAvailable ? '${account.reservations}' : '—',
        style: mono(12, color: context.srColors.ink3),
      ),
      Text(
        account.lastActive,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sans(11, color: context.srColors.muted),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: SrStatusChip(
          label: account.status.label,
          tone: account.status.tone,
        ),
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
                  style: mono(
                    10.5,
                    height: 1.45,
                    color: context.srColors.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: SR.space8),
          SrStatusChip(label: account.status.label, tone: account.status.tone),
        ],
      ),
      const SizedBox(height: SR.space12),
      Wrap(
        spacing: SR.space8,
        runSpacing: SR.space8,
        children: [
          SrFactChip(label: 'Role', value: account.role.label),
          SrFactChip(
            label: external ? 'Access' : 'Verification',
            value: external ? 'Paying client' : account.verification.label,
          ),
          SrFactChip(
            label: 'Reservations',
            value: account.activityMetricsAvailable
                ? '${account.reservations}'
                : '—',
          ),
          SrFactChip(label: 'Last active', value: account.lastActive),
        ],
      ),
    ],
  );
}
