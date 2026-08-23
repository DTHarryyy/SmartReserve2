import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/loyalty.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/record_table.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';

/// Pushed via Navigator, mirroring AssistantChatPage.
class LoyaltyPage extends StatefulWidget {
  const LoyaltyPage({super.key});

  @override
  State<LoyaltyPage> createState() => _LoyaltyPageState();
}

class _LoyaltyPageState extends State<LoyaltyPage> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = AppScope.read(context);
      if (state.loyalty == null && !state.loyaltyLoading) {
        unawaited(state.refreshLoyalty());
      }
    });
  }

  Future<void> _redeem(AppState state, LoyaltyReward reward) async {
    final balance = state.loyalty?.balance ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => SrConfirmDialog(
        title: 'Redeem this reward?',
        content: Text(
          '${reward.name} costs ${reward.pointsCost} points. '
          'Your balance is $balance.',
        ),
        confirmLabel: 'Redeem',
        onConfirm: () => Navigator.of(context).pop(true),
        onCancel: () => Navigator.of(context).pop(false),
      ),
    );
    if (confirmed == true) {
      await state.redeemReward(reward);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return AnimatedBuilder(
      animation: AppScope.of(context),
      builder: (context, _) {
        final state = AppScope.of(context);
        final loyalty = state.loyalty;
        return Scaffold(
          backgroundColor: c.canvas,
          appBar: AppBar(
            title: const Text('Loyalty & rewards'),
            backgroundColor: c.canvas,
            surfaceTintColor: Colors.transparent,
          ),
          body: SafeArea(
            child: state.loyaltyLoading && loyalty == null
                ? const SrLoadingState()
                : state.loyaltyError != null && loyalty == null
                ? SrErrorState(
                    message: state.loyaltyError!,
                    onRetry: () => unawaited(state.refreshLoyalty()),
                  )
                : _content(context, state, loyalty ?? const LoyaltySummary()),
          ),
        );
      },
    );
  }

  Widget _content(BuildContext context, AppState state, LoyaltySummary loyalty) {
    final c = context.srColors;
    final wide = context.fitsSplitView;
    final activity = _ActivitySection(loyalty: loyalty);
    final rewards = _RewardsSection(
      state: state,
      loyalty: loyalty,
      onRedeem: (reward) => unawaited(_redeem(state, reward)),
    );
    return SrScrollView(
      padding: SR.pageInsets(MediaQuery.sizeOf(context).width),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BalanceHero(loyalty: loyalty),
            const SizedBox(height: 20),
            if (wide)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: rewards),
                    const SizedBox(width: 20),
                    Expanded(child: activity),
                  ],
                ),
              )
            else ...[
              SrTabs(
                items: const [
                  SrTabItem(label: 'Activity'),
                  SrTabItem(label: 'Rewards'),
                ],
                selectedIndex: _tab,
                onSelect: (i) => setState(() => _tab = i),
              ),
              const SizedBox(height: 16),
              _tab == 0 ? activity : rewards,
            ],
            const SizedBox(height: 24),
            Text('How you earn points', style: SrType.subhead(color: c.text)),
            const SizedBox(height: 8),
            for (final type in LoyaltyTransactionType.values)
              if (loyalty.ruleFor(type) > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SrListRow(
                    icon: type.icon,
                    label: type.label,
                    value: '+${loyalty.ruleFor(type)}',
                    tone: type.tone,
                  ),
                ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _BalanceHero extends StatelessWidget {
  const _BalanceHero({required this.loyalty});

  final LoyaltySummary loyalty;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return SrCard(
      level: SrCardLevel.tinted,
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: c.brand,
              borderRadius: BorderRadius.circular(SR.rFull),
            ),
            child: const Icon(
              Icons.stars_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${loyalty.balance} points',
                  style: SrType.display(color: c.text),
                ),
                const SizedBox(height: 4),
                Text(
                  'Earned ${loyalty.lifetimeEarned} · Redeemed ${loyalty.lifetimeRedeemed}',
                  style: SrType.bodySm(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivitySection extends StatelessWidget {
  const _ActivitySection({required this.loyalty});

  final LoyaltySummary loyalty;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    if (loyalty.transactions.isEmpty) {
      return const ListEmptyState(
        icon: Icons.stars_rounded,
        title: 'No points yet',
        body: 'You haven\'t earned any loyalty points yet. Complete a '
            'reservation or leave feedback to start earning.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Recent activity', style: SrType.subhead(color: c.text)),
        const SizedBox(height: 10),
        SrCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < loyalty.transactions.length; i++) ...[
                if (i > 0) Divider(height: 1, color: c.border),
                _LedgerTile(transaction: loyalty.transactions[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _LedgerTile extends StatelessWidget {
  const _LedgerTile({required this.transaction});

  final LoyaltyTransaction transaction;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final positive = transaction.isCredit;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: transaction.type.tone.tint,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(transaction.type.icon, size: 17, color: transaction.type.tone.ink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  transaction.description.isEmpty
                      ? transaction.type.label
                      : transaction.description,
                  style: sans(13, w: 500, color: c.text),
                ),
                const SizedBox(height: 2),
                Text(_relative(transaction.createdAt), style: SrType.caption(color: c.textMuted)),
              ],
            ),
          ),
          Text(
            transaction.signedLabel,
            style: mono(13, w: 600, color: positive ? c.success : c.error),
          ),
        ],
      ),
    );
  }

  static String _relative(DateTime value) {
    final diff = DateTime.now().difference(value);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} hours ago';
    if (diff.inDays < 30) return '${diff.inDays} days ago';
    return '${value.day}/${value.month}/${value.year}';
  }
}

class _RewardsSection extends StatelessWidget {
  const _RewardsSection({
    required this.state,
    required this.loyalty,
    required this.onRedeem,
  });

  final AppState state;
  final LoyaltySummary loyalty;
  final ValueChanged<LoyaltyReward> onRedeem;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    if (loyalty.rewards.isEmpty) {
      return const ListEmptyState(
        icon: Icons.card_giftcard_rounded,
        title: 'No rewards available',
        body: 'Check back soon -- administrators are still setting up the '
            'rewards catalog.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Rewards', style: SrType.subhead(color: c.text)),
        const SizedBox(height: 10),
        for (final reward in loyalty.rewards)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _RewardCard(
              reward: reward,
              balance: loyalty.balance,
              pending: state.redemptionsPending.contains(reward.id),
              onRedeem: () => onRedeem(reward),
            ),
          ),
      ],
    );
  }
}

class _RewardCard extends StatelessWidget {
  const _RewardCard({
    required this.reward,
    required this.balance,
    required this.pending,
    required this.onRedeem,
  });

  final LoyaltyReward reward;
  final int balance;
  final bool pending;
  final VoidCallback onRedeem;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    final affordable = reward.canAfford(balance) && reward.active && !reward.isOutOfStock;
    return SrCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(reward.name, style: sans(14, w: 600, color: c.text)),
                if (reward.description.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(reward.description, style: SrType.bodySm(color: c.textMuted)),
                ],
                const SizedBox(height: 6),
                Text(
                  '${reward.pointsCost} points',
                  style: sans(12, w: 600, color: c.brand),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SrButton(
                label: pending ? 'Redeeming…' : 'Redeem',
                kind: SrButtonKind.primary,
                dense: true,
                onPressed: affordable && !pending ? onRedeem : null,
              ),
              if (!affordable && !pending) ...[
                const SizedBox(height: 4),
                Text(
                  !reward.active
                      ? 'Inactive'
                      : reward.isOutOfStock
                      ? 'Out of stock'
                      : 'Needs ${reward.pointsCost - balance} more',
                  style: SrType.caption(color: c.textMuted),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
