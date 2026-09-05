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

String _shortDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _shortDateTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${_shortDate(local)} $hour:$minute';
}

class LoyaltyAdminScreen extends StatefulWidget {
  const LoyaltyAdminScreen({super.key});

  @override
  State<LoyaltyAdminScreen> createState() => _LoyaltyAdminScreenState();
}

class _LoyaltyAdminScreenState extends State<LoyaltyAdminScreen> {
  final _search = TextEditingController();
  final _voucherSearch = TextEditingController();
  String _voucherStatus = 'all';
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = AppScope.read(context);
      if (state.isExternalAdmin &&
          state.loyaltyBalances.isEmpty &&
          state.loyaltyDiscountOffers.isEmpty &&
          state.loyaltyAdminClaims.isEmpty &&
          !state.loyaltyBalancesLoading &&
          !state.loyaltyDiscountOffersLoading &&
          !state.loyaltyAdminClaimsLoading) {
        state.refreshExternalLoyaltyAdmin();
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _voucherSearch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppScope.of(context),
      builder: (context, _) {
        final state = AppScope.of(context);
        if (!state.isExternalAdmin) {
          return Padding(
            padding: SR.pageInsets(MediaQuery.sizeOf(context).width),
            child: const ListEmptyState(
              icon: Icons.lock_outline_rounded,
              title: 'Loyalty is unavailable',
              body: 'This administrator role cannot access that area.',
            ),
          );
        }
        return Padding(
          padding: SR.pageInsets(MediaQuery.sizeOf(context).width),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SrPageHeader(
                title: 'Loyalty',
                description:
                    'Guest renter points, claimable discounts, and voucher history.',
              ),
              const SizedBox(height: 16),
              SrTabs(
                items: [
                  SrTabItem(
                    label: 'Balances',
                    icon: Icons.stars_rounded,
                    count: state.loyaltyBalances.length,
                  ),
                  SrTabItem(
                    label: 'Discounts',
                    icon: Icons.local_offer_rounded,
                    count: state.loyaltyDiscountOffers.length,
                  ),
                  SrTabItem(
                    label: 'Vouchers',
                    icon: Icons.confirmation_number_rounded,
                    count: state.loyaltyAdminClaims.length,
                  ),
                ],
                selectedIndex: _tabIndex,
                onSelect: (index) => setState(() => _tabIndex = index),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: switch (_tabIndex) {
                  0 => _BalancesTab(state: state, search: _search),
                  1 => const _ExternalDiscountCatalog(),
                  _ => _VouchersTab(
                    state: state,
                    search: _voucherSearch,
                    selectedStatus: _voucherStatus,
                    onStatusChanged: (status) {
                      setState(() => _voucherStatus = status);
                      state.refreshLoyaltyAdminClaims(
                        search: _voucherSearch.text,
                        status: status == 'all'
                            ? null
                            : LoyaltyDiscountClaimStatus.fromRaw(status),
                      );
                    },
                  ),
                },
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
                              formatPoints(row.balance),
                              style: mono(
                                12,
                                w: 600,
                                color: context.srColors.text,
                              ),
                            ),
                            Text(
                              formatPoints(row.lifetimeEarned),
                              style: mono(12),
                            ),
                            Text(
                              formatPoints(row.lifetimeRedeemed),
                              style: mono(12),
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
        Text(
          '${formatPoints(row.balance)} pts',
          style: mono(13, w: 600, color: c.text),
        ),
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
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.read(context).refreshLoyaltyLedger(widget.row.userId);
    });
  }

  @override
  void dispose() {
    _pointsController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _adjust(AppState state) async {
    final points = double.tryParse(_pointsController.text.trim());
    final reason = _reasonController.text.trim();
    if (points == null ||
        points == 0 ||
        (points * 2).roundToDouble() != points * 2 ||
        reason.isEmpty) {
      setState(
        () => _error = 'Enter a nonzero half-point amount and a reason.',
      );
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
            final ledger =
                state.loyaltyLedgerByUser[widget.row.userId] ??
                const <LoyaltyTransaction>[];
            final ledgerLoading = state.loyaltyLedgerLoading.contains(
              widget.row.userId,
            );
            final ledgerError = state.loyaltyLedgerErrors[widget.row.userId];
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
                              value: formatPoints(widget.row.balance),
                            ),
                            SrKeyCell(
                              label: 'EARNED',
                              value: formatPoints(widget.row.lifetimeEarned),
                            ),
                            SrKeyCell(
                              label: 'REDEEMED',
                              value: formatPoints(widget.row.lifetimeRedeemed),
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
                          placeholder: 'Points (e.g. 2.5 or -1)',
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
                        const SizedBox(height: 24),
                        Text('Activity', style: SrType.subhead(color: c.text)),
                        const SizedBox(height: 10),
                        if (ledgerLoading && ledger.isEmpty)
                          const SkeletonRow(
                            columns: [
                              ColSpec('DATE', flex: 2),
                              ColSpec('POINTS', width: 80),
                              ColSpec('TYPE', flex: 2),
                            ],
                            leadWidth: 24,
                          )
                        else if (ledgerError != null)
                          SrErrorState(
                            message: ledgerError,
                            onRetry: () =>
                                state.refreshLoyaltyLedger(widget.row.userId),
                          )
                        else if (ledger.isEmpty)
                          const ListEmptyState(
                            icon: Icons.history_rounded,
                            title: 'No loyalty activity',
                            body: 'Transactions will appear here.',
                          )
                        else
                          Column(
                            children: [
                              for (final item in ledger.take(30))
                                _LedgerTile(transaction: item),
                            ],
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

class _LedgerTile extends StatelessWidget {
  const _LedgerTile({required this.transaction});

  final LoyaltyTransaction transaction;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(transaction.type.icon, size: 18, color: c.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(transaction.type.label, style: sans(12.5, w: 600)),
                if (transaction.description.trim().isNotEmpty)
                  Text(
                    transaction.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: SrType.caption(color: c.textMuted),
                  ),
                Text(
                  _shortDateTime(transaction.createdAt),
                  style: SrType.caption(color: c.textMuted),
                ),
                if (transaction.type ==
                        LoyaltyTransactionType.adminAdjustment &&
                    transaction.actorId != null)
                  Text(
                    'Actor ${transaction.actorId}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SrType.caption(color: c.textMuted),
                  ),
              ],
            ),
          ),
          Text(
            transaction.signedLabel,
            style: mono(
              12,
              w: 700,
              color: transaction.isCredit ? SR.green : c.text,
            ),
          ),
        ],
      ),
    );
  }
}

class _VouchersTab extends StatelessWidget {
  const _VouchersTab({
    required this.state,
    required this.search,
    required this.selectedStatus,
    required this.onStatusChanged,
  });

  final AppState state;
  final TextEditingController search;
  final String selectedStatus;
  final ValueChanged<String> onStatusChanged;

  static const _columns = <ColSpec>[
    ColSpec('RENTER', flex: 3),
    ColSpec('OFFER', flex: 3),
    ColSpec('VALUE', width: 110, hide: ColumnHide.small),
    ColSpec('POINTS', width: 80, alignRight: true),
    ColSpec('STATUS', width: 110),
    ColSpec('RESERVATION', flex: 2, hide: ColumnHide.medium),
  ];

  @override
  Widget build(BuildContext context) {
    final claims = state.loyaltyAdminClaims;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilterBar(
          count: '${claims.length} shown',
          children: [
            FilterSearch(
              controller: search,
              placeholder: 'Search renter, email, or offer',
              onChanged: (value) => state.refreshLoyaltyAdminClaims(
                search: value,
                status: selectedStatus == 'all'
                    ? null
                    : LoyaltyDiscountClaimStatus.fromRaw(selectedStatus),
              ),
            ),
            SizedBox(
              width: 160,
              child: SrSelect<String>(
                value: selectedStatus,
                items: const [
                  'all',
                  'claimed',
                  'applied',
                  'consumed',
                  'expired',
                ],
                labelOf: (value) => switch (value) {
                  'claimed' => 'Claimed',
                  'applied' => 'Applied',
                  'consumed' => 'Consumed',
                  'expired' => 'Expired',
                  _ => 'All statuses',
                },
                onChanged: (value) {
                  if (value != null) onStatusChanged(value);
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: state.loyaltyAdminClaimsLoading && claims.isEmpty
              ? ListView(
                  children: [
                    for (var i = 0; i < 5; i++)
                      const SkeletonRow(columns: _columns, leadWidth: 28),
                  ],
                )
              : state.loyaltyAdminClaimsError != null && claims.isEmpty
              ? SrErrorState(
                  message: state.loyaltyAdminClaimsError!,
                  onRetry: () => state.refreshLoyaltyAdminClaims(
                    search: search.text,
                    status: selectedStatus == 'all'
                        ? null
                        : LoyaltyDiscountClaimStatus.fromRaw(selectedStatus),
                  ),
                )
              : claims.isEmpty
              ? const ListEmptyState(
                  icon: Icons.confirmation_number_rounded,
                  title: 'No vouchers yet',
                  body: 'Claimed loyalty discounts will appear here.',
                )
              : SingleChildScrollView(
                  child: RecordTable(
                    columns: _columns,
                    children: [
                      for (final claim in claims)
                        RecordRow(
                          columns: _columns,
                          compactChild: _CompactVoucherCard(claim: claim),
                          cells: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  claim.renterLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  claim.renterEmail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: SrType.caption(
                                    color: context.srColors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  claim.offerName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${claim.scopeLabel} · expires ${_shortDate(claim.expiryDate)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: SrType.caption(
                                    color: context.srColors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                            Text(claim.valueLabel, style: mono(12)),
                            Text(
                              formatPoints(claim.pointsSpent),
                              style: mono(12),
                            ),
                            SrStatusChip(
                              label: claim.effectiveStatus.label,
                              tone: claim.effectiveStatus.tone,
                              dense: true,
                            ),
                            Text(
                              claim.reservationId ?? '—',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: mono(11),
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
}

class _CompactVoucherCard extends StatelessWidget {
  const _CompactVoucherCard({required this.claim});

  final LoyaltyAdminClaimRow claim;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(claim.renterLabel, style: sans(13.5, w: 600)),
              Text(
                '${claim.offerName} · ${claim.valueLabel} · ${formatPoints(claim.pointsSpent)} pts',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: SrType.caption(color: c.textMuted),
              ),
              if (claim.releaseReason?.trim().isNotEmpty == true)
                Text(
                  claim.releaseReason ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SrType.caption(color: c.textMuted),
                ),
            ],
          ),
        ),
        SrStatusChip(
          label: claim.effectiveStatus.label,
          tone: claim.effectiveStatus.tone,
          dense: true,
        ),
      ],
    );
  }
}

class _ExternalDiscountCatalog extends StatelessWidget {
  const _ExternalDiscountCatalog();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final offers = state.loyaltyDiscountOffers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: SrButton(
            label: 'New discount',
            kind: SrButtonKind.primary,
            icon: const Icon(Icons.add_rounded, size: 16),
            onPressed: () => _openEditor(context, state, null),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: state.loyaltyDiscountOffersLoading && offers.isEmpty
              ? ListView(
                  children: const [
                    SkeletonRow(columns: _discountColumns, leadWidth: 30),
                    SkeletonRow(columns: _discountColumns, leadWidth: 30),
                    SkeletonRow(columns: _discountColumns, leadWidth: 30),
                  ],
                )
              : state.loyaltyDiscountOffersError != null && offers.isEmpty
              ? SrErrorState(
                  message: state.loyaltyDiscountOffersError!,
                  onRetry: () => state.refreshLoyaltyDiscountOffers(),
                )
              : offers.isEmpty
              ? const ListEmptyState(
                  icon: Icons.local_offer_rounded,
                  title: 'No discounts yet',
                  body:
                      'Create the first loyalty discount for guest-priced renters.',
                )
              : SingleChildScrollView(
                  child: RecordTable(
                    columns: _discountColumns,
                    children: [
                      for (final offer in offers)
                        RecordRow(
                          columns: _discountColumns,
                          onTap: () => _openEditor(context, state, offer),
                          compactChild: _CompactDiscountCard(offer: offer),
                          cells: [
                            Text(
                              offer.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(offer.valueLabel, style: mono(12)),
                            Text(
                              formatPoints(offer.requiredPoints),
                              style: mono(12),
                            ),
                            Text(
                              offer.scopeLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: mono(12),
                            ),
                            SrToggle(
                              value: offer.active,
                              label: offer.active ? 'Active' : 'Inactive',
                              onChanged: (value) =>
                                  state.setLoyaltyDiscountOfferActive(
                                    offer.id,
                                    value,
                                  ),
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

  static const _discountColumns = <ColSpec>[
    ColSpec('NAME', flex: 3),
    ColSpec('VALUE', width: 110),
    ColSpec('POINTS', width: 80, alignRight: true),
    ColSpec('SCOPE', flex: 2, hide: ColumnHide.small),
    ColSpec('ACTIVE', width: 90),
  ];

  void _openEditor(
    BuildContext context,
    AppState state,
    LoyaltyDiscountOffer? offer,
  ) {
    showDialog<void>(
      context: context,
      builder: (_) => _DiscountEditorDialog(state: state, offer: offer),
    );
  }
}

class _CompactDiscountCard extends StatelessWidget {
  const _CompactDiscountCard({required this.offer});

  final LoyaltyDiscountOffer offer;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(offer.name, style: sans(13.5, w: 600)),
              Text(
                '${offer.valueLabel} · ${formatPoints(offer.requiredPoints)} pts',
                style: SrType.caption(color: c.textMuted),
              ),
            ],
          ),
        ),
        SrStatusChip(
          label: offer.active ? 'Active' : 'Inactive',
          tone: offer.active ? SrTone.success : SrTone.neutral,
          dense: true,
        ),
      ],
    );
  }
}

class _DiscountEditorDialog extends StatefulWidget {
  const _DiscountEditorDialog({required this.state, this.offer});

  final AppState state;
  final LoyaltyDiscountOffer? offer;

  @override
  State<_DiscountEditorDialog> createState() => _DiscountEditorDialogState();
}

class _DiscountEditorDialogState extends State<_DiscountEditorDialog> {
  final _scrollController = ScrollController();
  final _nameFocus = FocusNode();
  final _descriptionFocus = FocusNode();
  final _pointsFocus = FocusNode();
  final _valueFocus = FocusNode();
  final _nameKey = GlobalKey();
  final _descriptionKey = GlobalKey();
  final _pointsKey = GlobalKey();
  final _valueKey = GlobalKey();
  final _validFromKey = GlobalKey();
  final _validUntilKey = GlobalKey();
  late final _name = TextEditingController(text: widget.offer?.name ?? '');
  late final _description = TextEditingController(
    text: widget.offer?.description ?? '',
  );
  late final _points = TextEditingController(
    text: widget.offer == null
        ? ''
        : formatPoints(widget.offer!.requiredPoints),
  );
  late final _value = TextEditingController(
    text: widget.offer == null
        ? ''
        : widget.offer!.discountKind == DiscountKind.fixedAmount
        ? ((widget.offer!.fixedAmountCentavos ?? 0) / 100).toStringAsFixed(2)
        : formatPoints(widget.offer!.percentage ?? 0),
  );
  late DateTime _validFromDate = _stripTime(
    widget.offer?.validFrom ?? DateTime.now(),
  );
  late DateTime _validUntilDate = _stripTime(
    widget.offer?.validUntil ?? DateTime.now().add(const Duration(days: 30)),
  );
  late final _validFrom = TextEditingController(
    text: _dateOnly(_validFromDate),
  );
  late final _validUntil = TextEditingController(
    text: _dateOnly(_validUntilDate),
  );
  late DiscountKind _kind =
      widget.offer?.discountKind ?? DiscountKind.fixedAmount;
  late String _scope = widget.offer?.facilityId ?? 'all';
  late bool _active = widget.offer?.active ?? true;
  bool _saving = false;
  String? _error;
  String? _nameError;
  String? _descriptionError;
  String? _pointsError;
  String? _valueError;
  String? _validFromError;
  String? _validUntilError;
  String? _dateNote;
  int _validationErrorCount = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    _nameFocus.dispose();
    _descriptionFocus.dispose();
    _pointsFocus.dispose();
    _valueFocus.dispose();
    _name.dispose();
    _description.dispose();
    _points.dispose();
    _value.dispose();
    _validFrom.dispose();
    _validUntil.dispose();
    super.dispose();
  }

  void _clearFieldError(String field) {
    setState(() {
      switch (field) {
        case 'name':
          _nameError = null;
        case 'description':
          _descriptionError = null;
        case 'points':
          _pointsError = null;
        case 'value':
          _valueError = null;
        case 'validFrom':
          _validFromError = null;
        case 'validUntil':
          _validUntilError = null;
      }
      _error = null;
      _validationErrorCount = 0;
    });
  }

  bool _isHalfPoint(num value) => (value * 2).roundToDouble() == value * 2;

  void _syncDateControllers() {
    _validFrom.text = _dateOnly(_validFromDate);
    _validUntil.text = _dateOnly(_validUntilDate);
  }

  Future<void> _pickDate({required bool validFrom}) async {
    final now = _stripTime(DateTime.now());
    final initialDate = validFrom
        ? _validFromDate
        : (_validUntilDate.isBefore(_validFromDate)
              ? _validFromDate
              : _validUntilDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: validFrom ? DateTime(now.year - 5) : _validFromDate,
      lastDate: DateTime(now.year + 10, 12, 31),
      helpText: validFrom
          ? 'Choose valid from date'
          : 'Choose valid until date',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (validFrom) {
        _validFromDate = _stripTime(picked);
        if (_validUntilDate.isBefore(_validFromDate)) {
          _validUntilDate = _validFromDate;
          _dateNote = 'Valid until was adjusted to match the new start date.';
        } else {
          _dateNote = null;
        }
        _validFromError = null;
      } else {
        _validUntilDate = _stripTime(picked);
        _dateNote = null;
        _validUntilError = null;
      }
      _error = null;
      _syncDateControllers();
    });
  }

  void _focusFirstInvalid() {
    final targets = [
      (_nameError, _nameKey, _nameFocus),
      (_descriptionError, _descriptionKey, _descriptionFocus),
      (_pointsError, _pointsKey, _pointsFocus),
      (_valueError, _valueKey, _valueFocus),
      (_validFromError, _validFromKey, null),
      (_validUntilError, _validUntilKey, null),
    ];
    for (final target in targets) {
      if (target.$1 == null) continue;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = target.$2.currentContext;
        if (context != null) {
          Scrollable.ensureVisible(
            context,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: .12,
          );
        }
        target.$3?.requestFocus();
      });
      return;
    }
  }

  Future<void> _save() async {
    final points = double.tryParse(_points.text.trim());
    final value = double.tryParse(_value.text.trim());
    final validFrom = DateTime.tryParse(_validFrom.text.trim());
    final validUntil = DateTime.tryParse(_validUntil.text.trim());
    var hasError = false;

    setState(() {
      _error = null;
      _nameError = null;
      _descriptionError = null;
      _pointsError = null;
      _valueError = null;
      _validFromError = null;
      _validUntilError = null;
      _dateNote = null;
      _validationErrorCount = 0;

      final name = _name.text.trim();
      if (name.isEmpty) {
        _nameError = 'Discount name is required.';
        hasError = true;
      } else if (name.length < 3) {
        _nameError = 'Use at least 3 characters.';
        hasError = true;
      } else if (name.length > 80) {
        _nameError = 'Keep the name within 80 characters.';
        hasError = true;
      }
      if (_description.text.trim().length > 400) {
        _descriptionError = 'Keep the description within 400 characters.';
        hasError = true;
      }
      if (_points.text.trim().isEmpty) {
        _pointsError = 'Points required is required.';
        hasError = true;
      } else if (points == null) {
        _pointsError = 'Enter a number, such as 2.5.';
        hasError = true;
      } else if (points <= 0) {
        _pointsError = 'Enter a positive point value.';
        hasError = true;
      } else if (!_isHalfPoint(points)) {
        _pointsError = 'Use whole or half points only, such as 2 or 2.5.';
        hasError = true;
      }
      if (_value.text.trim().isEmpty) {
        _valueError = _kind == DiscountKind.fixedAmount
            ? 'Discount amount is required.'
            : 'Discount percentage is required.';
        hasError = true;
      } else if (value == null) {
        _valueError = _kind == DiscountKind.fixedAmount
            ? 'Enter a PHP amount, such as 500 or 500.50.'
            : 'Enter a percentage, such as 10.';
        hasError = true;
      } else if (value <= 0) {
        _valueError = _kind == DiscountKind.fixedAmount
            ? 'Enter a positive PHP amount.'
            : 'Enter a percentage from 1 to 100.';
        hasError = true;
      } else if (_kind == DiscountKind.percentage && value > 100) {
        _valueError = 'Percentage discounts cannot exceed 100%.';
        hasError = true;
      }
      if (validFrom == null) {
        _validFromError = 'Valid from is required.';
        hasError = true;
      }
      if (validUntil == null) {
        _validUntilError = 'Valid until is required.';
        hasError = true;
      } else if (validFrom != null && validUntil.isBefore(validFrom)) {
        _validUntilError = 'Valid until must be on or after valid from.';
        hasError = true;
      }

      final fieldErrors = [
        _nameError,
        _descriptionError,
        _pointsError,
        _valueError,
        _validFromError,
        _validUntilError,
      ].whereType<String>().length;
      _validationErrorCount = fieldErrors;
      if (fieldErrors > 0) {
        final fieldWord = fieldErrors == 1 ? 'field' : 'fields';
        _error =
            'Please fix $fieldErrors highlighted $fieldWord before saving.';
      }
    });

    if (hasError) {
      _focusFirstInvalid();
      return;
    }

    final checkedPoints = points!;
    final checkedValue = value!;
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await widget.state.saveLoyaltyDiscountOffer(
      id: widget.offer?.id,
      name: _name.text.trim(),
      description: _description.text.trim(),
      requiredPoints: checkedPoints,
      discountKind: _kind,
      fixedAmountCentavos: _kind == DiscountKind.fixedAmount
          ? (checkedValue * 100).round()
          : null,
      percentage: _kind == DiscountKind.percentage ? checkedValue : null,
      facilityId: _scope == 'all' ? null : _scope,
      validFrom: validFrom!,
      validUntil: validUntil!,
      active: _active,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      Navigator.of(context).pop();
    } else {
      final message =
          widget.state.loyaltyDiscountOfferSaveError ??
          'That discount could not be saved. Please review the fields and try again.';
      setState(() => _applyServerError(message));
      _focusFirstInvalid();
    }
  }

  void _applyServerError(String message) {
    _error = message;
    _validationErrorCount = 0;
    final lower = message.toLowerCase();
    if (lower.contains('name')) {
      _nameError = message;
      _validationErrorCount++;
    } else if (lower.contains('description')) {
      _descriptionError = message;
      _validationErrorCount++;
    } else if (lower.contains('point')) {
      _pointsError = message;
      _validationErrorCount++;
    } else if (lower.contains('percentage') || lower.contains('percent')) {
      _valueError = message;
      _validationErrorCount++;
    } else if (lower.contains('amount') || lower.contains('fixed')) {
      _valueError = message;
      _validationErrorCount++;
    } else if (lower.contains('date') ||
        lower.contains('valid_from') ||
        lower.contains('valid until') ||
        lower.contains('valid_until')) {
      _validUntilError = message;
      _validationErrorCount++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final scopeItems = <String>[
      'all',
      for (final facility in widget.state.facilities) facility.id,
    ];
    final amountLabel = _kind == DiscountKind.fixedAmount
        ? 'Discount amount (PHP)'
        : 'Discount percentage (%)';
    final amountHelper = _kind == DiscountKind.fixedAmount
        ? 'Enter the peso amount to deduct.'
        : 'Enter a value from 1 to 100.';
    String scopeLabel(String id) {
      if (id == 'all') return 'All guest bookings';
      for (final facility in widget.state.facilities) {
        if (facility.id == id) return facility.name;
      }
      return 'Selected facility';
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: SrAdaptiveDialog(
        maxWidth: 560,
        maxHeight: 760,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.offer == null ? 'New discount' : 'Edit discount',
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
                controller: _scrollController,
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Required fields are marked *.',
                      style: SrType.caption(color: c.textMuted),
                    ),
                    const SizedBox(height: 14),
                    if (_error != null) ...[
                      _DiscountFormErrorSummary(
                        message: _error!,
                        count: _validationErrorCount,
                      ),
                      const SizedBox(height: 14),
                    ],
                    const _DiscountFormSectionTitle('Discount details'),
                    _LabeledDiscountField(
                      key: _nameKey,
                      label: 'Discount name',
                      required: true,
                      helper: 'Shown to renters when they claim this discount.',
                      error: _nameError,
                      child: SrTextField(
                        controller: _name,
                        focusNode: _nameFocus,
                        placeholder: 'e.g. Welcome discount',
                        semanticLabel: 'Discount name',
                        hasError: _nameError != null,
                        onChanged: (_) => _clearFieldError('name'),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _LabeledDiscountField(
                      key: _descriptionKey,
                      label: 'Description',
                      helper: 'Optional short explanation shown to renters.',
                      error: _descriptionError,
                      child: SrTextField(
                        controller: _description,
                        focusNode: _descriptionFocus,
                        placeholder: 'Short renter-facing description',
                        semanticLabel: 'Description',
                        hasError: _descriptionError != null,
                        minLines: 2,
                        maxLines: 3,
                        onChanged: (_) => _clearFieldError('description'),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _LabeledDiscountField(
                      key: _pointsKey,
                      label: 'Points required',
                      required: true,
                      helper: 'Use whole or half points, e.g. 2.5.',
                      error: _pointsError,
                      child: SrTextField(
                        controller: _points,
                        focusNode: _pointsFocus,
                        placeholder: '2.5',
                        semanticLabel: 'Points required',
                        hasError: _pointsError != null,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (_) => _clearFieldError('points'),
                      ),
                    ),
                    const SizedBox(height: 22),
                    const _DiscountFormSectionTitle('Discount value'),
                    _ResponsiveDiscountPair(
                      first: _LabeledDiscountField(
                        label: 'Discount type',
                        required: true,
                        child: SrSelect<DiscountKind>(
                          value: _kind,
                          items: DiscountKind.values,
                          labelOf: (kind) => kind.label,
                          semanticLabel: 'Discount type',
                          onChanged: (kind) {
                            if (kind != null) {
                              setState(() {
                                _kind = kind;
                                _valueError = null;
                                _error = null;
                              });
                            }
                          },
                        ),
                      ),
                      second: _LabeledDiscountField(
                        key: _valueKey,
                        label: amountLabel,
                        required: true,
                        helper: amountHelper,
                        error: _valueError,
                        child: SrTextField(
                          controller: _value,
                          focusNode: _valueFocus,
                          placeholder: _kind == DiscountKind.fixedAmount
                              ? '500.00'
                              : '10',
                          semanticLabel: amountLabel,
                          hasError: _valueError != null,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          onChanged: (_) => _clearFieldError('value'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    const _DiscountFormSectionTitle('Applies to'),
                    _LabeledDiscountField(
                      label: 'Eligible bookings',
                      required: true,
                      helper:
                          'Choose a facility to limit this discount to that facility’s guest bookings.',
                      child: SrSelect<String>(
                        value: _scope,
                        items: scopeItems,
                        labelOf: scopeLabel,
                        semanticLabel: 'Eligible bookings',
                        onChanged: (value) {
                          if (value != null) setState(() => _scope = value);
                        },
                      ),
                    ),
                    const SizedBox(height: 22),
                    const _DiscountFormSectionTitle('Availability period'),
                    _ResponsiveDiscountPair(
                      first: _LabeledDiscountField(
                        key: _validFromKey,
                        label: 'Valid from',
                        required: true,
                        error: _validFromError,
                        child: _DiscountDateField(
                          value: _friendlyDate(_validFromDate),
                          hasError: _validFromError != null,
                          semanticLabel: 'Valid from',
                          onTap: () => _pickDate(validFrom: true),
                        ),
                      ),
                      second: _LabeledDiscountField(
                        key: _validUntilKey,
                        label: 'Valid until',
                        required: true,
                        helper: _dateNote,
                        error: _validUntilError,
                        child: _DiscountDateField(
                          value: _friendlyDate(_validUntilDate),
                          hasError: _validUntilError != null,
                          semanticLabel: 'Valid until',
                          onTap: () => _pickDate(validFrom: false),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    const _DiscountFormSectionTitle('Status'),
                    _LabeledDiscountField(
                      label: 'Offer status',
                      required: true,
                      child: _DiscountStatusToggle(
                        active: _active,
                        onChanged: (value) => setState(() => _active = value),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: c.border),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SrButton(
                label: _saving ? 'Saving…' : 'Save discount',
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

  static String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static DateTime _stripTime(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static String _friendlyDate(DateTime value) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[value.month - 1]} ${value.day}, ${value.year}';
  }
}

class _DiscountFormSectionTitle extends StatelessWidget {
  const _DiscountFormSectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(label, style: sans(12, w: 700, color: context.srColors.text)),
  );
}

class _DiscountFormErrorSummary extends StatelessWidget {
  const _DiscountFormErrorSummary({required this.message, required this.count});

  final String message;
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final fieldPhrase = count == 1 ? 'field needs' : 'fields need';
    final title = count > 0
        ? '$count $fieldPhrase attention'
        : 'Discount could not be saved';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.redTint,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: c.redLine),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: c.red),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: sans(12.5, w: 700, color: c.red)),
                const SizedBox(height: 3),
                Text(message, style: sans(11.5, height: 1.4, color: c.red)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LabeledDiscountField extends StatelessWidget {
  const _LabeledDiscountField({
    super.key,
    required this.label,
    required this.child,
    this.required = false,
    this.helper,
    this.error,
  });

  final String label;
  final Widget child;
  final bool required;
  final String? helper;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final helperText = error ?? helper;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SrLabel(label, required: required),
        child,
        if (helperText != null && helperText.trim().isNotEmpty) ...[
          const SizedBox(height: 5),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (error != null) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 1, right: 5),
                  child: Icon(
                    Icons.error_outline_rounded,
                    size: 11,
                    color: c.red,
                  ),
                ),
              ],
              Expanded(
                child: Text(
                  helperText,
                  style: sans(
                    11,
                    height: 1.35,
                    color: error == null ? c.textMuted : c.red,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ResponsiveDiscountPair extends StatelessWidget {
  const _ResponsiveDiscountPair({required this.first, required this.second});

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 480) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 12), second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: first),
          const SizedBox(width: 12),
          Expanded(child: second),
        ],
      );
    },
  );
}

class _DiscountDateField extends StatelessWidget {
  const _DiscountDateField({
    required this.value,
    required this.onTap,
    required this.semanticLabel,
    this.hasError = false,
  });

  final String value;
  final VoidCallback onTap;
  final String semanticLabel;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Semantics(
      button: true,
      label: semanticLabel,
      value: value,
      child: Hoverable(
        builder: (context, hovered) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: SR.stateChange,
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: hasError
                    ? c.red
                    : (hovered ? c.borderHover : c.borderField),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sans(13, color: c.text),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.calendar_today_rounded, size: 15, color: c.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DiscountStatusToggle extends StatelessWidget {
  const _DiscountStatusToggle({required this.active, required this.onChanged});

  final bool active;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final label = active
        ? 'Active — renters can claim this discount'
        : 'Inactive — existing vouchers remain valid, but new claims are blocked';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: c.borderField),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: sans(12, height: 1.35, color: c.text)),
          ),
          const SizedBox(width: 12),
          SrToggle(value: active, label: label, onChanged: onChanged),
        ],
      ),
    );
  }
}
