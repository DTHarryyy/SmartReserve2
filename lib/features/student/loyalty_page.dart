import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/loyalty.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';

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

      if (state.shouldRefreshLoyaltyForCurrentUser &&
          state.loyalty == null &&
          !state.loyaltyLoading) {
        unawaited(state.refreshLoyalty());
      }
    });
  }

  Future<void> _redeem(AppState state, LoyaltyReward reward) async {
    if (!state.loyaltyAvailableForCurrentUser) return;

    final balance = state.loyalty?.balance ?? 0;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => SrConfirmDialog(
        title: 'Redeem reward?',
        content: Text(
          '${reward.name} costs ${reward.pointsCost} points. '
          'You currently have $balance points.',
        ),
        confirmLabel: 'Redeem',
        onConfirm: () {
          Navigator.of(context).pop(true);
        },
        onCancel: () {
          Navigator.of(context).pop(false);
        },
      ),
    );

    if (confirmed == true) {
      await state.redeemReward(reward);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppScope.of(context),
      builder: (context, _) {
        final state = AppScope.of(context);
        final loyalty = state.loyalty;
        final c = context.srColors;
        final unavailable =
            !state.shouldRefreshLoyaltyForCurrentUser ||
            loyalty?.eligible == false;
        final failedInitialLoad =
            state.loyaltyError != null && loyalty == null;
        final loadingInitial =
            state.loyaltyLoading ||
            (loyalty == null && state.loyaltyError == null);

        return Scaffold(
          backgroundColor: c.canvas,
          appBar: AppBar(
            title: Text(unavailable ? 'Unavailable' : 'Loyalty & rewards'),
            backgroundColor: c.canvas,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
          ),
          body: SafeArea(
            child: unavailable
                ? const _LoyaltyUnavailableState()
                : failedInitialLoad
                ? SrErrorState(
                    message: state.loyaltyError!,
                    onRetry: () {
                      unawaited(state.refreshLoyalty());
                    },
                  )
                : loadingInitial
                ? const SrLoadingState()
                : _content(context, state, loyalty!),
          ),
        );
      },
    );
  }

  Widget _content(
    BuildContext context,
    AppState state,
    LoyaltySummary loyalty,
  ) {
    final width = MediaQuery.sizeOf(context).width;

    final mobile = width < 600;
    final desktop = width >= 980;

    final activity = _ActivitySection(loyalty: loyalty);

    final rewards = _RewardsSection(
      state: state,
      loyalty: loyalty,
      onRedeem: (reward) {
        unawaited(_redeem(state, reward));
      },
    );

    return SrScrollView(
      padding: SR.pageInsets(width),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BalanceHero(loyalty: loyalty),

              SizedBox(height: mobile ? 16 : 22),

              if (desktop)
                _DesktopContent(rewards: rewards, activity: activity)
              else ...[
                SrTabs(
                  items: const [
                    SrTabItem(label: 'Activity'),
                    SrTabItem(label: 'Rewards'),
                  ],
                  selectedIndex: _tab,
                  onSelect: (index) {
                    setState(() {
                      _tab = index;
                    });
                  },
                ),

                const SizedBox(height: 16),

                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _tab == 0
                      ? KeyedSubtree(
                          key: const ValueKey('activity'),
                          child: activity,
                        )
                      : KeyedSubtree(
                          key: const ValueKey('rewards'),
                          child: rewards,
                        ),
                ),
              ],

              SizedBox(height: mobile ? 24 : 30),

              _EarnPointsSection(loyalty: loyalty),

              SizedBox(height: mobile ? 24 : 36),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoyaltyUnavailableState extends StatelessWidget {
  const _LoyaltyUnavailableState();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;

    return SrScrollView(
      padding: SR.pageInsets(width),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: const _LoyaltyEmptyState(
            icon: Icons.lock_outline_rounded,
            title: 'Loyalty is available to guest renters',
            body:
                'Verified students, faculty, and staff use campus pricing, so rewards and points are not available on this account.',
          ),
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final mobile = constraints.maxWidth < 600;

        return SrCard(
          level: SrCardLevel.tinted,
          padding: EdgeInsets.all(mobile ? 16 : 22),
          child: mobile
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _HeroIcon(size: 46),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Available balance',
                                style: SrType.caption(color: c.textMuted),
                              ),
                              const SizedBox(height: 2),
                              _BalanceText(
                                balance: loyalty.balance,
                                mobile: true,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _HeroStat(
                            label: 'Earned',
                            value: '${loyalty.lifetimeEarned}',
                            icon: Icons.add_circle_outline_rounded,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _HeroStat(
                            label: 'Redeemed',
                            value: '${loyalty.lifetimeRedeemed}',
                            icon: Icons.redeem_rounded,
                          ),
                        ),
                      ],
                    ),
                  ],
                )
              : Row(
                  children: [
                    const _HeroIcon(size: 56),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Available balance',
                            style: SrType.bodySm(color: c.textMuted),
                          ),
                          const SizedBox(height: 3),
                          _BalanceText(balance: loyalty.balance, mobile: false),
                        ],
                      ),
                    ),
                    const SizedBox(width: 18),
                    _DesktopHeroStat(
                      label: 'Lifetime earned',
                      value: loyalty.lifetimeEarned,
                    ),
                    const SizedBox(width: 28),
                    _DesktopHeroStat(
                      label: 'Redeemed',
                      value: loyalty.lifetimeRedeemed,
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _HeroIcon extends StatelessWidget {
  const _HeroIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: context.srColors.brand,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(Icons.stars_rounded, color: Colors.white, size: size * 0.52),
    );
  }
}

class _BalanceText extends StatelessWidget {
  const _BalanceText({required this.balance, required this.mobile});

  final int balance;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: Text(
            '$balance',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sans(mobile ? 26 : 32, w: 700, color: c.text),
          ),
        ),
        const SizedBox(width: 6),
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text(
            'points',
            style: sans(mobile ? 12 : 13, w: 500, color: c.textMuted),
          ),
        ),
      ],
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: .65),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: c.brand),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono(13, w: 600, color: c.text),
                ),
                const SizedBox(height: 1),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SrType.caption(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopHeroStat extends StatelessWidget {
  const _DesktopHeroStat({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$value', style: mono(15, w: 600, color: c.text)),
        const SizedBox(height: 2),
        Text(label, style: SrType.caption(color: c.textMuted)),
      ],
    );
  }
}

class _DesktopContent extends StatelessWidget {
  const _DesktopContent({required this.rewards, required this.activity});

  final Widget rewards;
  final Widget activity;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 10, child: rewards),
        const SizedBox(width: 20),
        Expanded(flex: 11, child: activity),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.description, this.trailing});

  final String title;
  final String? description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: SrType.subhead(color: c.text)),
              if (description != null) ...[
                const SizedBox(height: 3),
                Text(description!, style: SrType.caption(color: c.textMuted)),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
      ],
    );
  }
}

class _ActivitySection extends StatelessWidget {
  const _ActivitySection({required this.loyalty});

  final LoyaltySummary loyalty;

  @override
  Widget build(BuildContext context) {
    if (loyalty.transactions.isEmpty) {
      return const _LoyaltyEmptyState(
        icon: Icons.history_rounded,
        title: 'No activity yet',
        body:
            'Complete a reservation or leave feedback to start earning loyalty points.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(
          title: 'Recent activity',
          description: 'Your latest points earned and redeemed.',
        ),
        const SizedBox(height: 12),
        SrCard(
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < loyalty.transactions.length; i++) ...[
                if (i > 0) Divider(height: 1, color: context.srColors.border),
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 390;

        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: narrow ? 12 : 14,
            vertical: 12,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: transaction.type.tone.tint,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(
                  transaction.type.icon,
                  size: 17,
                  color: transaction.type.tone.ink,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      transaction.description.trim().isEmpty
                          ? transaction.type.label
                          : transaction.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: sans(12.5, w: 500, color: c.text),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _relative(transaction.createdAt),
                      style: SrType.caption(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: (positive ? c.success : c.error).withValues(
                    alpha: .08,
                  ),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  transaction.signedLabel,
                  style: mono(
                    11.5,
                    w: 600,
                    color: positive ? c.success : c.error,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _relative(DateTime value) {
    final diff = DateTime.now().difference(value);

    if (diff.inMinutes < 1) {
      return 'Just now';
    }

    if (diff.inHours < 1) {
      return '${diff.inMinutes} min ago';
    }

    if (diff.inDays < 1) {
      return '${diff.inHours} '
          '${diff.inHours == 1 ? 'hour' : 'hours'} ago';
    }

    if (diff.inDays < 30) {
      return '${diff.inDays} '
          '${diff.inDays == 1 ? 'day' : 'days'} ago';
    }

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
    if (loyalty.rewards.isEmpty) {
      return const _LoyaltyEmptyState(
        icon: Icons.card_giftcard_rounded,
        title: 'No rewards available',
        body: 'New rewards will appear here when they become available.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(
          title: 'Rewards',
          description: 'Use your points for available rewards.',
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < loyalty.rewards.length; i++) ...[
          _RewardCard(
            reward: loyalty.rewards[i],
            balance: loyalty.balance,
            pending: state.redemptionsPending.contains(loyalty.rewards[i].id),
            onRedeem: () {
              onRedeem(loyalty.rewards[i]);
            },
          ),
          if (i != loyalty.rewards.length - 1) const SizedBox(height: 10),
        ],
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

    final affordable =
        reward.canAfford(balance) && reward.active && !reward.isOutOfStock;

    final remaining = reward.pointsCost - balance;

    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 430;

        return SrCard(
          padding: EdgeInsets.all(stacked ? 14 : 16),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _RewardDetails(reward: reward),
                    const SizedBox(height: 14),
                    _RewardAction(
                      reward: reward,
                      balance: balance,
                      affordable: affordable,
                      pending: pending,
                      remaining: remaining,
                      fullWidth: true,
                      onRedeem: onRedeem,
                    ),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: _RewardDetails(reward: reward)),
                    const SizedBox(width: 18),
                    _RewardAction(
                      reward: reward,
                      balance: balance,
                      affordable: affordable,
                      pending: pending,
                      remaining: remaining,
                      fullWidth: false,
                      onRedeem: onRedeem,
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _RewardDetails extends StatelessWidget {
  const _RewardDetails({required this.reward});

  final LoyaltyReward reward;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: c.brand.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.card_giftcard_rounded, size: 20, color: c.brand),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                reward.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: sans(13.5, w: 600, color: c.text),
              ),
              if (reward.description.trim().isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  reward.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: SrType.bodySm(color: c.textMuted),
                ),
              ],
              const SizedBox(height: 7),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.stars_rounded, size: 15, color: c.brand),
                  const SizedBox(width: 4),
                  Text(
                    '${reward.pointsCost} points',
                    style: sans(11.5, w: 600, color: c.brand),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RewardAction extends StatelessWidget {
  const _RewardAction({
    required this.reward,
    required this.balance,
    required this.affordable,
    required this.pending,
    required this.remaining,
    required this.fullWidth,
    required this.onRedeem,
  });

  final LoyaltyReward reward;
  final int balance;
  final bool affordable;
  final bool pending;
  final int remaining;
  final bool fullWidth;
  final VoidCallback onRedeem;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;

    String? status;

    if (!pending && !affordable) {
      if (!reward.active) {
        status = 'Inactive';
      } else if (reward.isOutOfStock) {
        status = 'Out of stock';
      } else {
        status = 'Need ${remaining > 0 ? remaining : 0} more points';
      }
    }

    final content = Column(
      crossAxisAlignment: fullWidth
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.end,
      children: [
        SrButton(
          label: pending ? 'Redeeming…' : 'Redeem',
          kind: SrButtonKind.primary,
          dense: true,
          onPressed: affordable && !pending ? onRedeem : null,
        ),
        if (status != null) ...[
          const SizedBox(height: 5),
          Text(
            status,
            textAlign: fullWidth ? TextAlign.left : TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SrType.caption(color: c.textMuted),
          ),
        ],
      ],
    );

    if (fullWidth) {
      return SizedBox(width: double.infinity, child: content);
    }

    return content;
  }
}

class _EarnPointsSection extends StatelessWidget {
  const _EarnPointsSection({required this.loyalty});

  final LoyaltySummary loyalty;

  @override
  Widget build(BuildContext context) {
    final rules = [
      for (final type in LoyaltyTransactionType.values)
        if (loyalty.ruleFor(type) > 0) type,
    ];

    if (rules.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(
          title: 'How you earn points',
          description: 'Ways to build your loyalty balance.',
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 10.0;

            final columns = constraints.maxWidth >= 900
                ? 3
                : constraints.maxWidth >= 560
                ? 2
                : 1;

            final itemWidth =
                (constraints.maxWidth - ((columns - 1) * gap)) / columns;

            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final type in rules)
                  SizedBox(
                    width: itemWidth,
                    child: _EarnRuleCard(
                      type: type,
                      points: loyalty.ruleFor(type),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _EarnRuleCard extends StatelessWidget {
  const _EarnRuleCard({required this.type, required this.points});

  final LoyaltyTransactionType type;
  final int points;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: type.tone.tint,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(type.icon, size: 17, color: type.tone.ink),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              type.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sans(12, w: 500, color: c.text),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: c.brand.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(100),
            ),
            child: Text('+$points', style: mono(11, w: 600, color: c.brand)),
          ),
        ],
      ),
    );
  }
}

class _LoyaltyEmptyState extends StatelessWidget {
  const _LoyaltyEmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 180),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: c.brand.withValues(alpha: .08),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 22, color: c.brand),
          ),
          const SizedBox(height: 13),
          Text(
            title,
            textAlign: TextAlign.center,
            style: sans(13.5, w: 600, color: c.text),
          ),
          const SizedBox(height: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Text(
              body,
              textAlign: TextAlign.center,
              style: sans(11.5, height: 1.45, color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
