import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/loyalty.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/record_table.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';

/// Internal-admin-only screen; app_shell wires it to AppView.loyalty.
class LoyaltyAdminScreen extends StatefulWidget {
  const LoyaltyAdminScreen({super.key});

  @override
  State<LoyaltyAdminScreen> createState() => _LoyaltyAdminScreenState();
}

class _LoyaltyAdminScreenState extends State<LoyaltyAdminScreen> {
  int _tab = 0;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.read(context).refreshLoyaltyBalances();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppScope.of(context),
      builder: (context, _) {
        final state = AppScope.of(context);
        return Padding(
          padding: SR.pageInsets(MediaQuery.sizeOf(context).width),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SrPageHeader(
                title: 'Loyalty',
                description:
                    'Balances, ledger history, and the rewards catalog.',
              ),
              const SizedBox(height: 16),
              SrTabs(
                items: const [
                  SrTabItem(label: 'Balances'),
                  SrTabItem(label: 'Rewards'),
                ],
                selectedIndex: _tab,
                onSelect: (i) => setState(() => _tab = i),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _tab == 0
                    ? _BalancesTab(state: state, search: _search)
                    : _RewardsTab(state: state),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BalancesTab extends StatelessWidget {
  const _BalancesTab({required this.state, required this.search});

  final AppState state;
  final TextEditingController search;

  static const _columns = <ColSpec>[
    ColSpec('PERSON', flex: 3),
    ColSpec('EMAIL', flex: 3, hide: ColumnHide.medium),
    ColSpec('BALANCE', width: 90, alignRight: true),
    ColSpec('EARNED', width: 90, hide: ColumnHide.small, alignRight: true),
    ColSpec('REDEEMED', width: 90, hide: ColumnHide.small, alignRight: true),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilterBar(
          count: '${state.loyaltyBalances.length} shown',
          children: [
            FilterSearch(
              controller: search,
              placeholder: 'Search by name or email',
              onChanged: (v) => state.refreshLoyaltyBalances(search: v),
            ),
          ],
        ),
        Expanded(
          child: state.loyaltyBalancesLoading && state.loyaltyBalances.isEmpty
              ? ListView(
                  children: [
                    for (var i = 0; i < 6; i++)
                      const SkeletonRow(columns: _columns, leadWidth: 30),
                  ],
                )
              : state.loyaltyBalancesError != null &&
                    state.loyaltyBalances.isEmpty
              ? SrErrorState(
                  message: state.loyaltyBalancesError!,
                  onRetry: () => state.refreshLoyaltyBalances(),
                )
              : state.loyaltyBalances.isEmpty
              ? const ListEmptyState(
                  icon: Icons.stars_rounded,
                  title: 'No balances yet',
                  body:
                      'Once users start completing reservations, their '
                      'loyalty balances will appear here.',
                )
              : SingleChildScrollView(
                  child: RecordTable(
                    columns: _columns,
                    children: [
                      for (final row in state.loyaltyBalances)
                        RecordRow(
                          columns: _columns,
                          onTap: () => _openDetail(context, row),
                          compactChild: _CompactBalanceCard(row: row),
                          cells: [
                            Text(
                              row.fullName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              row.email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: mono(
                                11,
                                color: context.srColors.textMuted,
                              ),
                            ),
                            Text(
                              '${row.balance}',
                              style: mono(
                                12,
                                w: 600,
                                color: context.srColors.text,
                              ),
                            ),
                            Text('${row.lifetimeEarned}', style: mono(12)),
                            Text('${row.lifetimeRedeemed}', style: mono(12)),
                          ],
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  void _openDetail(BuildContext context, LoyaltyBalanceRow row) {
    showDialog<void>(
      context: context,
      builder: (_) => _BalanceDetailDialog(row: row),
    );
  }
}

class _CompactBalanceCard extends StatelessWidget {
  const _CompactBalanceCard({required this.row});

  final LoyaltyBalanceRow row;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(row.fullName, style: sans(13.5, w: 600)),
              Text(row.email, style: SrType.caption(color: c.textMuted)),
            ],
          ),
        ),
        Text('${row.balance} pts', style: mono(13, w: 600, color: c.text)),
      ],
    );
  }
}

class _BalanceDetailDialog extends StatefulWidget {
  const _BalanceDetailDialog({required this.row});

  final LoyaltyBalanceRow row;

  @override
  State<_BalanceDetailDialog> createState() => _BalanceDetailDialogState();
}

class _BalanceDetailDialogState extends State<_BalanceDetailDialog> {
  final _pointsController = TextEditingController();
  final _reasonController = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _pointsController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _adjust(AppState state) async {
    final points = int.tryParse(_pointsController.text.trim());
    final reason = _reasonController.text.trim();
    if (points == null || points == 0 || reason.isEmpty) {
      setState(() => _error = 'Enter a nonzero amount and a reason.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await state.adjustLoyaltyPoints(
      userId: widget.row.userId,
      points: points,
      reason: reason,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      _pointsController.clear();
      _reasonController.clear();
      if (mounted) Navigator.of(context).pop();
    } else {
      setState(() => _error = 'That adjustment could not be saved.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: SrAdaptiveDialog(
        maxWidth: 480,
        maxHeight: 620,
        child: AnimatedBuilder(
          animation: AppScope.of(context),
          builder: (context, _) {
            final state = AppScope.of(context);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.row.fullName,
                              style: SrType.title(color: c.text),
                            ),
                            Text(
                              widget.row.email,
                              style: SrType.caption(color: c.textMuted),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: c.border),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SrCellGrid(
                          columns: 3,
                          children: [
                            SrKeyCell(
                              label: 'BALANCE',
                              value: '${widget.row.balance}',
                            ),
                            SrKeyCell(
                              label: 'EARNED',
                              value: '${widget.row.lifetimeEarned}',
                            ),
                            SrKeyCell(
                              label: 'REDEEMED',
                              value: '${widget.row.lifetimeRedeemed}',
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Adjust points',
                          style: SrType.subhead(color: c.text),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Creates a ledger entry and an audit record. Use a '
                          'positive amount to award, negative to deduct.',
                          style: SrType.caption(color: c.textMuted),
                        ),
                        const SizedBox(height: 10),
                        SrTextField(
                          controller: _pointsController,
                          placeholder: 'Points (e.g. 50 or -20)',
                          keyboardType: const TextInputType.numberWithOptions(
                            signed: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SrTextField(
                          controller: _reasonController,
                          placeholder: 'Reason (required)',
                          minLines: 2,
                          maxLines: 3,
                        ),
                        SrErrorText(_error),
                        const SizedBox(height: 10),
                        SrButton(
                          label: _saving ? 'Saving…' : 'Apply adjustment',
                          kind: SrButtonKind.caution,
                          onPressed: _saving ? null : () => _adjust(state),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RewardsTab extends StatelessWidget {
  const _RewardsTab({required this.state});

  final AppState state;

  static const _columns = <ColSpec>[
    ColSpec('NAME', flex: 3),
    ColSpec('POINTS', width: 80, alignRight: true),
    ColSpec('STOCK', width: 90, hide: ColumnHide.small),
    ColSpec('ACTIVE', width: 90),
  ];

  @override
  Widget build(BuildContext context) {
    final rewards = state.loyalty?.rewards ?? const <LoyaltyReward>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: SrButton(
            label: 'New reward',
            kind: SrButtonKind.primary,
            icon: const Icon(Icons.add_rounded, size: 16),
            onPressed: () => _openEditor(context, state, null),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: rewards.isEmpty
              ? const ListEmptyState(
                  icon: Icons.card_giftcard_rounded,
                  title: 'No rewards yet',
                  body:
                      'Create the first reward for students to redeem '
                      'with their loyalty points.',
                )
              : SingleChildScrollView(
                  child: RecordTable(
                    columns: _columns,
                    children: [
                      for (final reward in rewards)
                        RecordRow(
                          columns: _columns,
                          onTap: () => _openEditor(context, state, reward),
                          compactChild: _CompactRewardCard(reward: reward),
                          cells: [
                            Text(
                              reward.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text('${reward.pointsCost}', style: mono(12)),
                            Text(
                              reward.isUnlimited
                                  ? 'Unlimited'
                                  : '${reward.stock}',
                              style: mono(12),
                            ),
                            SrToggle(
                              value: reward.active,
                              label: reward.active ? 'Active' : 'Inactive',
                              onChanged: (v) =>
                                  state.setLoyaltyRewardActive(reward.id, v),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  void _openEditor(
    BuildContext context,
    AppState state,
    LoyaltyReward? reward,
  ) {
    showDialog<void>(
      context: context,
      builder: (_) => _RewardEditorDialog(state: state, reward: reward),
    );
  }
}

class _CompactRewardCard extends StatelessWidget {
  const _CompactRewardCard({required this.reward});

  final LoyaltyReward reward;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(reward.name, style: sans(13.5, w: 600)),
              Text(
                '${reward.pointsCost} points',
                style: SrType.caption(color: c.textMuted),
              ),
            ],
          ),
        ),
        SrStatusChip(
          label: reward.active ? 'Active' : 'Inactive',
          tone: reward.active ? SrTone.success : SrTone.neutral,
          dense: true,
        ),
      ],
    );
  }
}

class _RewardEditorDialog extends StatefulWidget {
  const _RewardEditorDialog({required this.state, this.reward});

  final AppState state;
  final LoyaltyReward? reward;

  @override
  State<_RewardEditorDialog> createState() => _RewardEditorDialogState();
}

class _RewardEditorDialogState extends State<_RewardEditorDialog> {
  late final _name = TextEditingController(text: widget.reward?.name ?? '');
  late final _description = TextEditingController(
    text: widget.reward?.description ?? '',
  );
  late final _points = TextEditingController(
    text: widget.reward == null ? '' : '${widget.reward!.pointsCost}',
  );
  late final _stock = TextEditingController(
    text: widget.reward?.stock == null ? '' : '${widget.reward!.stock}',
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _points.dispose();
    _stock.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final points = int.tryParse(_points.text.trim());
    if (_name.text.trim().length < 3 || points == null || points <= 0) {
      setState(() => _error = 'Enter a name and a positive points cost.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await widget.state.saveLoyaltyReward(
      id: widget.reward?.id,
      name: _name.text.trim(),
      description: _description.text.trim(),
      pointsCost: points,
      active: widget.reward?.active ?? true,
      stock: _stock.text.trim().isEmpty
          ? null
          : int.tryParse(_stock.text.trim()),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = 'That reward could not be saved.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: SrAdaptiveDialog(
        maxWidth: 460,
        maxHeight: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.reward == null ? 'New reward' : 'Edit reward',
                      style: SrType.title(color: c.text),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SrTextField(controller: _name, placeholder: 'Reward name'),
                    const SizedBox(height: 8),
                    SrTextField(
                      controller: _description,
                      placeholder: 'Description (optional)',
                      minLines: 2,
                      maxLines: 3,
                    ),
                    const SizedBox(height: 8),
                    SrTextField(
                      controller: _points,
                      placeholder: 'Points required',
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 8),
                    SrTextField(
                      controller: _stock,
                      placeholder: 'Stock (leave blank for unlimited)',
                      keyboardType: TextInputType.number,
                    ),
                    SrErrorText(_error),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: c.border),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SrButton(
                label: _saving ? 'Saving…' : 'Save reward',
                kind: SrButtonKind.primary,
                expand: true,
                onPressed: _saving ? null : _save,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
