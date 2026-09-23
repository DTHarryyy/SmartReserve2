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

  Future<void> _claim(AppState state, LoyaltyDiscountOffer offer) async {
    if (!state.loyaltyAvailableForCurrentUser) return;

    final balance = state.loyalty?.balance ?? 0;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => SrConfirmDialog(
        title: 'Claim discount?',
        content: Text(
          '${offer.name} costs ${formatPoints(offer.requiredPoints)} points. '
          'You currently have ${formatPoints(balance)} points.',
        ),
        confirmLabel: 'Claim',
        onConfirm: () {
          Navigator.of(context).pop(true);
        },
        onCancel: () {
          Navigator.of(context).pop(false);
        },
      ),
    );

    if (confirmed == true) {
      await state.claimLoyaltyDiscount(offer);
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
        final failedInitialLoad = state.loyaltyError != null && loyalty == null;
        final loadingInitial =
            state.loyaltyLoading ||
            (loyalty == null && state.loyaltyError == null);

        return Scaffold(
          backgroundColor: c.canvas,
          appBar: AppBar(
            title: Text(unavailable ? 'Unavailable' : 'Loyalty discounts'),
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

    final discounts = _DiscountsSection(
      state: state,
      loyalty: loyalty,
      onClaim: (offer) {
        unawaited(_claim(state, offer));
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
                _DesktopContent(discounts: discounts, activity: activity)
              else ...[
                SrTabs(
                  items: const [
                    SrTabItem(label: 'Activity'),
                    SrTabItem(label: 'Discounts'),
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
                          key: const ValueKey('discounts'),
                          child: discounts,
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
            title: 'Loyalty is available to external-rate renters',
            body:
                'Verified students, faculty, and staff use campus pricing, so loyalty discounts and points are not available on this account.',
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
                            value: formatPoints(loyalty.lifetimeEarned),
                            icon: Icons.add_circle_outline_rounded,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _HeroStat(
                            label: 'Redeemed',
                            value: formatPoints(loyalty.lifetimeRedeemed),
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

  final double balance;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: Text(
            formatPoints(balance),
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
  final double value;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(formatPoints(value), style: mono(15, w: 600, color: c.text)),
        const SizedBox(height: 2),
        Text(label, style: SrType.caption(color: c.textMuted)),
      ],
    );
  }
}

class _DesktopContent extends StatelessWidget {
  const _DesktopContent({required this.discounts, required this.activity});

  final Widget discounts;
  final Widget activity;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 10, child: discounts),
        const SizedBox(width: 20),
        Expanded(flex: 11, child: activity),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.description});

  final String title;
  final String? description;

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

class _DiscountsSection extends StatelessWidget {
  const _DiscountsSection({
    required this.state,
    required this.loyalty,
    required this.onClaim,
  });

  final AppState state;
  final LoyaltySummary loyalty;
  final ValueChanged<LoyaltyDiscountOffer> onClaim;

  @override
  Widget build(BuildContext context) {
    if (loyalty.offers.isEmpty && loyalty.claims.isEmpty) {
      return const _LoyaltyEmptyState(
        icon: Icons.local_offer_rounded,
        title: 'No discounts available',
        body: 'Discount campaigns will appear here when they become available.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(
          title: 'Discounts',
          description: 'Claim a one-booking voucher with your points.',
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < loyalty.offers.length; i++) ...[
          _DiscountOfferCard(
            offer: loyalty.offers[i],
            balance: loyalty.balance,
            pending: state.discountClaimsPending.contains(loyalty.offers[i].id),
            onClaim: () {
              onClaim(loyalty.offers[i]);
            },
          ),
          if (i != loyalty.offers.length - 1) const SizedBox(height: 10),
        ],
        if (loyalty.claims.isNotEmpty) ...[
          const SizedBox(height: 18),
          const _SectionHeader(
            title: 'My vouchers',
            description: 'Claimed discounts for future bookings.',
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < loyalty.claims.length; i++) ...[
            _VoucherCard(claim: loyalty.claims[i]),
            if (i != loyalty.claims.length - 1) const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }
}

class _DiscountOfferCard extends StatelessWidget {
  const _DiscountOfferCard({
    required this.offer,
    required this.balance,
    required this.pending,
    required this.onClaim,
  });

  final LoyaltyDiscountOffer offer;
  final double balance;
  final bool pending;
  final VoidCallback onClaim;

  @override
  Widget build(BuildContext context) {
    final affordable = offer.canAfford(balance) && offer.active;
    final remaining = offer.requiredPoints - balance;

    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 430;

        return SrCard(
          padding: EdgeInsets.all(stacked ? 14 : 16),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DiscountOfferDetails(offer: offer),
                    const SizedBox(height: 14),
                    _DiscountOfferAction(
                      balance: balance,
                      affordable: affordable,
                      pending: pending,
                      remaining: remaining,
                      fullWidth: true,
                      onClaim: onClaim,
                    ),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: _DiscountOfferDetails(offer: offer)),
                    const SizedBox(width: 18),
                    _DiscountOfferAction(
                      balance: balance,
                      affordable: affordable,
                      pending: pending,
                      remaining: remaining,
                      fullWidth: false,
                      onClaim: onClaim,
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _DiscountOfferDetails extends StatelessWidget {
  const _DiscountOfferDetails({required this.offer});

  final LoyaltyDiscountOffer offer;

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
          child: Icon(Icons.local_offer_rounded, size: 20, color: c.brand),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                offer.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: sans(13.5, w: 600, color: c.text),
              ),
              if (offer.description.trim().isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  offer.description,
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
                    '${formatPoints(offer.requiredPoints)} points',
                    style: sans(11.5, w: 600, color: c.brand),
                  ),
                  const SizedBox(width: 10),
                  Icon(Icons.sell_rounded, size: 15, color: c.textMuted),
                  const SizedBox(width: 4),
                  Text(
                    offer.valueLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SrType.caption(color: c.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                '${offer.scopeLabel} · until ${offer.validUntil.month}/${offer.validUntil.day}/${offer.validUntil.year}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SrType.caption(color: c.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DiscountOfferAction extends StatelessWidget {
  const _DiscountOfferAction({
    required this.balance,
    required this.affordable,
    required this.pending,
    required this.remaining,
    required this.fullWidth,
    required this.onClaim,
  });

  final double balance;
  final bool affordable;
  final bool pending;
  final double remaining;
  final bool fullWidth;
  final VoidCallback onClaim;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;

    String? status;

    if (!pending && !affordable) {
      status =
          'Need ${formatPoints(remaining > 0 ? remaining : 0)} more points';
    }

    final content = Column(
      crossAxisAlignment: fullWidth
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.end,
      children: [
        SrButton(
          label: pending ? 'Claiming…' : 'Claim',
          kind: SrButtonKind.primary,
          dense: true,
          onPressed: affordable && !pending ? onClaim : null,
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

class _VoucherCard extends StatelessWidget {
  const _VoucherCard({required this.claim});

  final LoyaltyDiscountClaim claim;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return SrCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: claim.status.tone.tint,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.confirmation_number_rounded,
              size: 18,
              color: claim.status.tone.ink,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  claim.offerName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: sans(13, w: 600, color: c.text),
                ),
                const SizedBox(height: 3),
                Text(
                  '${claim.valueLabel} · ${claim.scopeLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SrType.caption(color: c.textMuted),
                ),
                const SizedBox(height: 3),
                Text(
                  'Valid until ${claim.expiryDate.month}/${claim.expiryDate.day}/${claim.expiryDate.year}',
                  style: SrType.caption(color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SrStatusChip(
            label: claim.status.label,
            tone: claim.status.tone,
            dense: true,
          ),
        ],
      ),
    );
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
  final double points;

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
            child: Text(
              '+${formatPoints(points)}',
              style: mono(11, w: 600, color: c.brand),
            ),
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
