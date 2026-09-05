import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/app_view.dart';
import '../theme/sr_tokens.dart';
import 'sr_controls.dart';
import 'sr_logo.dart';

import '../theme/sr_theme.dart';

const adminSections = <AppView>[
  AppView.facilities,
  AppView.reservations,
  AppView.calendar,
  AppView.verifications,
  AppView.feedback,
  AppView.anomalies,
  AppView.users,
  AppView.loyalty,
  AppView.reports,
  AppView.audit,
];

typedef NavGroup = ({String label, List<AppView> items});

const _internalGroups = <NavGroup>[
  (
    label: 'Operations',
    items: [
      AppView.facilities,
      AppView.reservations,
      AppView.calendar,
      AppView.verifications,
      AppView.feedback,
      AppView.anomalies,
    ],
  ),
  (
    label: 'Administration',
    items: [AppView.users, AppView.reports, AppView.audit],
  ),
];

const _externalGroups = <NavGroup>[
  (
    label: 'Operations',
    items: [
      AppView.facilities,
      AppView.reservations,
      AppView.calendar,
      AppView.feedback,
      AppView.anomalies,
    ],
  ),
  (
    label: 'Administration',
    items: [AppView.loyalty, AppView.reports, AppView.users, AppView.profile],
  ),
];

class SideNav extends StatefulWidget {
  const SideNav({
    super.key,
    required this.state,
    required this.onSelect,
    this.showStats = true,
  });

  final AppState state;
  final ValueChanged<AppView> onSelect;
  final bool showStats;

  static const width = 248.0;

  @override
  State<SideNav> createState() => _SideNavState();
}

class _SideNavState extends State<SideNav> {
  AppView? _hoveredSection;

  String? _totalFor(AppView section) => switch (section) {
    AppView.facilities => '${widget.state.facilities.length}',
    AppView.users => '${widget.state.accounts.length}',
    _ => null,
  };

  int _pendingFor(AppView section) => switch (section) {
    AppView.reservations => widget.state.pendingRequests,
    AppView.verifications => widget.state.pendingVerifications,
    AppView.anomalies => widget.state.anomalyActiveHighCriticalCount,
    _ => 0,
  };

  void _setHoveredSection(AppView section) {
    if (_hoveredSection == section) return;
    setState(() => _hoveredSection = section);
  }

  void _clearHoveredSection(AppView section) {
    if (_hoveredSection != section) return;
    setState(() => _hoveredSection = null);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final groups = state.isExternalAdmin ? _externalGroups : _internalGroups;
    return Container(
      width: SideNav.width,
      decoration: BoxDecoration(
        color: context.srColors.navBg,
        border: Border(right: BorderSide(color: context.srColors.navBorder)),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _BrandMark(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  SR.space12,
                  0,
                  SR.space12,
                  SR.space12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final group in groups) ...[
                      _GroupLabel(group.label),
                      for (final section in group.items)
                        _NavButton(
                          section: section,
                          icon: section.icon,
                          label:
                              state.isExternalAdmin && section == AppView.users
                              ? 'Clients'
                              : state.isExternalAdmin &&
                                    section == AppView.loyalty
                              ? 'Loyalty'
                              : section.crumb,
                          total: _totalFor(section),
                          pending: _pendingFor(section),
                          current: state.view.navSection == section,
                          hovered: _hoveredSection == section,
                          onHoverEnter: () => _setHoveredSection(section),
                          onHoverExit: () => _clearHoveredSection(section),
                          onTap: () => widget.onSelect(section),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            if (widget.showStats)
              _MappedStat(
                mapped: state.mappedCount,
                total: state.catalogueTotal,
              ),
            _AdminFooter(state: state, onSelect: widget.onSelect),
          ],
        ),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      SR.space20,
      SR.space20,
      SR.space20,
      SR.space16,
    ),
    child: Row(
      children: [
        const SrLogo(size: SR.controlSm, radius: SR.rSm),
        const SizedBox(width: SR.space12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SmartReserve',
                style: sans(15, w: 600, height: 1.1, tracking: -.015),
              ),
              const SizedBox(height: SR.space2),
              Text('CSU APARRI', style: SrType.overline()),
            ],
          ),
        ),
      ],
    ),
  );
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      SR.space12,
      SR.space12,
      SR.space12,
      SR.space6,
    ),
    child: Text(label.toUpperCase(), style: SrType.overline()),
  );
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.section,
    required this.icon,
    required this.label,
    required this.current,
    required this.hovered,
    required this.onHoverEnter,
    required this.onHoverExit,
    required this.onTap,
    required this.pending,
    this.total,
  });

  final AppView section;
  final IconData icon;
  final String label;
  final String? total;
  final int pending;
  final bool current;
  final bool hovered;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompact;
    return Semantics(
      button: true,
      selected: current,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHoverEnter(),
        onExit: (_) => onHoverExit(),
        child: GestureDetector(
          onTap: onTap,
          child: Stack(
            children: [
              Container(
                key: ValueKey('side-nav-item-${section.name}'),
                margin: const EdgeInsets.only(bottom: SR.space2),
                constraints: BoxConstraints(
                  minHeight: compact ? SR.tapTarget : 38,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: SR.space12,
                  vertical: SR.space8,
                ),
                decoration: BoxDecoration(
                  color: current
                      ? context.srColors.primaryTint
                      : (hovered
                            ? context.srColors.surfaceSubtle
                            : Colors.transparent),
                  borderRadius: BorderRadius.circular(SR.rSm),
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: SR.iconMd,
                      color: current
                          ? SR.primary
                          : (hovered
                                ? context.srColors.ink3
                                : context.srColors.ink4),
                    ),
                    const SizedBox(width: SR.space12),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sans(
                          13,
                          w: current ? 600 : 500,
                          color: current
                              ? context.srColors.primaryDeep
                              : (hovered
                                    ? context.srColors.ink
                                    : context.srColors.ink2),
                        ),
                      ),
                    ),
                    if (pending > 0)
                      _PendingBadge(count: pending, current: current)
                    else if (total != null)
                      Text(
                        total!,
                        style: mono(
                          10,
                          w: 500,
                          color: context.srColors.mutedLight,
                        ),
                      ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                top: SR.space8,
                bottom: SR.space12,
                child: AnimatedContainer(
                  duration: SR.stateChange,
                  curve: SR.easing,
                  width: 3,
                  decoration: BoxDecoration(
                    color: current ? SR.primary : Colors.transparent,
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(3),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PendingBadge extends StatelessWidget {
  const _PendingBadge({required this.count, required this.current});

  final int count;
  final bool current;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: SR.space6, vertical: 1),
    constraints: const BoxConstraints(minWidth: 20),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: current ? SR.primary : context.srColors.primaryTint,
      borderRadius: BorderRadius.circular(SR.rFull),
      border: current ? null : Border.all(color: context.srColors.primaryLine),
    ),
    child: Text(
      '$count',
      style: mono(
        10,
        w: 600,
        color: current ? SR.onDark : context.srColors.primaryDeep,
      ),
    ),
  );
}

class _MappedStat extends StatelessWidget {
  const _MappedStat({required this.mapped, required this.total});

  final int mapped;
  final int total;

  @override
  Widget build(BuildContext context) {
    final outstanding = (total - mapped).clamp(0, total);
    final complete = outstanding == 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(SR.space12, 0, SR.space12, SR.space12),
      padding: const EdgeInsets.all(SR.space12),
      decoration: BoxDecoration(
        color: complete
            ? context.srColors.greenTint
            : context.srColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(SR.rMd),
        border: Border.all(
          color: complete
              ? context.srColors.greenLine
              : context.srColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Mapped facilities',
            style: SrType.caption(w: 500, color: context.srColors.ink3),
          ),
          const SizedBox(height: SR.space4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$mapped',
                style: sans(
                  20,
                  w: 600,
                  tracking: -.02,
                  color: complete
                      ? context.srColors.greenDark
                      : context.srColors.ink,
                ),
              ),
              const SizedBox(width: SR.space6),
              Text('/ $total', style: mono(11, color: context.srColors.muted)),
            ],
          ),
          const SizedBox(height: SR.space8),
          ClipRRect(
            borderRadius: BorderRadius.circular(SR.rXs),
            child: Stack(
              children: [
                Container(
                  height: 5,
                  color: complete
                      ? context.srColors.greenLine
                      : context.srColors.surfaceSunken,
                ),
                AnimatedFractionallySizedBox(
                  duration: SR.progressSweep,
                  curve: SR.easing,
                  widthFactor: total == 0
                      ? 0
                      : (mapped / total).clamp(0.0, 1.0),
                  child: Container(
                    height: 5,
                    color: complete ? SR.green : SR.primary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: SR.space8),
          Text(
            complete
                ? 'Every facility has a verified pin.'
                : '$outstanding ${outstanding == 1 ? 'facility' : 'facilities'} '
                      'still ${outstanding == 1 ? 'needs' : 'need'} a verified '
                      'pin.',
            style: SrType.caption(
              color: complete
                  ? context.srColors.greenDark
                  : context.srColors.ink4,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminFooter extends StatelessWidget {
  const _AdminFooter({required this.state, required this.onSelect});

  final AppState state;
  final ValueChanged<AppView> onSelect;

  @override
  Widget build(BuildContext context) {
    final admin = state.currentAdmin;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.srColors.navBorder)),
      ),
      padding: const EdgeInsets.all(SR.space8),
      child: Semantics(
        button: true,
        label: 'Your profile',
        child: Hoverable(
          builder: (context, hovered) => GestureDetector(
            onTap: () => onSelect(AppView.profile),
            child: AnimatedContainer(
              duration: SR.stateChange,
              padding: const EdgeInsets.all(SR.space8),
              decoration: BoxDecoration(
                color: hovered
                    ? context.srColors.surfaceSubtle
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(SR.rSm),
              ),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: context.srColors.navAvatar,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      admin.initials,
                      style: mono(
                        10,
                        w: 600,
                        color: context.srColors.navAvatarFg,
                      ),
                    ),
                  ),
                  const SizedBox(width: SR.space8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          admin.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: sans(12, w: 600, color: context.srColors.ink),
                        ),
                        Text(
                          'Administrator · ${admin.role.label}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SrType.caption(),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: SR.iconMd,
                    color: hovered
                        ? context.srColors.ink3
                        : context.srColors.mutedLight,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
