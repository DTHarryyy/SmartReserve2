import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/app_view.dart';
import '../theme/sr_tokens.dart';
import 'sr_controls.dart';
import 'sr_logo.dart';

const adminSections = <AppView>[
  AppView.facilities,
  AppView.reservations,
  AppView.calendar,
  AppView.verifications,
  AppView.users,
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
    items: [AppView.facilities, AppView.reservations, AppView.calendar],
  ),
  (
    label: 'Administration',
    items: [AppView.reports, AppView.users, AppView.profile],
  ),
];

class SideNav extends StatelessWidget {
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

  String? _totalFor(AppView section) => switch (section) {
    AppView.facilities => '${state.facilities.length}',
    AppView.users => '${state.accounts.length}',
    _ => null,
  };

  int _pendingFor(AppView section) => switch (section) {
    AppView.reservations => state.pendingRequests,
    AppView.verifications => state.pendingVerifications,
    _ => 0,
  };

  @override
  Widget build(BuildContext context) {
    final groups = state.isExternalAdmin ? _externalGroups : _internalGroups;
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: SR.navBg,
        border: Border(right: BorderSide(color: SR.navBorder)),
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
                          icon: section.icon,
                          label:
                              state.isExternalAdmin && section == AppView.users
                              ? 'Clients'
                              : section.crumb,
                          total: _totalFor(section),
                          pending: _pendingFor(section),
                          current: state.view.navSection == section,
                          onTap: () => onSelect(section),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            if (showStats)
              _MappedStat(
                mapped: state.mappedCount,
                total: state.catalogueTotal,
              ),
            _AdminFooter(state: state, onSelect: onSelect),
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
    required this.icon,
    required this.label,
    required this.current,
    required this.onTap,
    required this.pending,
    this.total,
  });

  final IconData icon;
  final String label;
  final String? total;
  final int pending;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompact;
    return Semantics(
      button: true,
      selected: current,
      child: Hoverable(
        builder: (context, hovered) => GestureDetector(
          onTap: onTap,
          child: Stack(
            children: [
              AnimatedContainer(
                duration: SR.stateChange,
                curve: SR.easing,
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
                      ? SR.primaryTint
                      : (hovered ? SR.surfaceSubtle : Colors.transparent),
                  borderRadius: BorderRadius.circular(SR.rSm),
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: SR.iconMd,
                      color: current
                          ? SR.primary
                          : (hovered ? SR.ink3 : SR.ink4),
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
                              ? SR.primaryDeep
                              : (hovered ? SR.ink : SR.ink2),
                        ),
                      ),
                    ),
                    if (pending > 0)
                      _PendingBadge(count: pending, current: current)
                    else if (total != null)
                      Text(
                        total!,
                        style: mono(10, w: 500, color: SR.mutedLight),
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
      color: current ? SR.primary : SR.primaryTint,
      borderRadius: BorderRadius.circular(SR.rFull),
      border: current ? null : Border.all(color: SR.primaryLine),
    ),
    child: Text(
      '$count',
      style: mono(10, w: 600, color: current ? SR.onDark : SR.primaryDeep),
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
        color: complete ? SR.greenTint : SR.surfaceSubtle,
        borderRadius: BorderRadius.circular(SR.rMd),
        border: Border.all(color: complete ? SR.greenLine : SR.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Mapped facilities',
            style: SrType.caption(w: 500, color: SR.ink3),
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
                  color: complete ? SR.greenDark : SR.ink,
                ),
              ),
              const SizedBox(width: SR.space6),
              Text('/ $total', style: mono(11, color: SR.muted)),
            ],
          ),
          const SizedBox(height: SR.space8),
          ClipRRect(
            borderRadius: BorderRadius.circular(SR.rXs),
            child: Stack(
              children: [
                Container(
                  height: 5,
                  color: complete ? SR.greenLine : SR.surfaceSunken,
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
            style: SrType.caption(color: complete ? SR.greenDark : SR.ink4),
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
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: SR.navBorder)),
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
                color: hovered ? SR.surfaceSubtle : Colors.transparent,
                borderRadius: BorderRadius.circular(SR.rSm),
              ),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: SR.navAvatar,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      admin.initials,
                      style: mono(10, w: 600, color: SR.navAvatarFg),
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
                          style: sans(12, w: 600, color: SR.ink),
                        ),
                        Text(
                          'Registrar · ${admin.role.label}',
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
                    color: hovered ? SR.ink3 : SR.mutedLight,
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
