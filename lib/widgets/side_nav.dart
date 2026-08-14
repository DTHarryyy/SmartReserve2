import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../app/app_view.dart';
import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

const adminSections = <AppView>[
  AppView.facilities,
  AppView.reservations,
  AppView.calendar,
  AppView.verifications,
  AppView.users,
  AppView.reports,
  AppView.audit,
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

  static const width = 232.0;

  String? _countFor(AppView section) => switch (section) {
    AppView.facilities => '${state.facilities.length}',
    AppView.reservations =>
      state.pendingRequests == 0 ? null : '${state.pendingRequests}',
    AppView.verifications =>
      state.pendingVerifications == 0 ? null : '${state.pendingVerifications}',
    AppView.users => '${state.accounts.length}',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final sections = state.isExternalAdmin
        ? const [
            AppView.facilities,
            AppView.reservations,
            AppView.calendar,
            AppView.reports,
            AppView.users,
            AppView.profile,
          ]
        : adminSections;
    return Container(
      width: width,
      color: SR.navBg,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: SR.blue,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'S',
                      style: sans(13, w: 700, color: SR.surface),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SmartReserve',
                          style: sans(
                            14,
                            w: 600,
                            height: 1.1,
                            tracking: -.01,
                            color: SR.surface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'CSU APARRI',
                          style: mono(
                            10,
                            height: 1.4,
                            color: const Color(0x6BFFFFFF),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final section in sections)
                      _NavButton(
                        label: state.isExternalAdmin && section == AppView.users
                            ? 'Clients'
                            : section.crumb,
                        count: _countFor(section),
                        current: state.view.navSection == section,
                        onTap: () => onSelect(section),
                      ),
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

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.label,
    required this.current,
    required this.onTap,
    this.count,
  });

  final String label;
  final String? count;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: current,
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: SR.stateChange,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: current
                ? const Color(0x1FFFFFFF)
                : (hovered ? const Color(0x12FFFFFF) : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: current ? SR.blueBright : const Color(0x40FFFFFF),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sans(
                    13,
                    w: 500,
                    color: current || hovered
                        ? SR.surface
                        : const Color(0x9EFFFFFF),
                  ),
                ),
              ),
              if (count != null)
                Text(
                  count!,
                  style: mono(10, w: 500, color: const Color(0x4DFFFFFF)),
                ),
            ],
          ),
        ),
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
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Mapped facilities',
            style: sans(
              11,
              w: 500,
              height: 1.4,
              color: const Color(0x80FFFFFF),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$mapped',
                style: sans(20, w: 600, tracking: -.02, color: SR.surface),
              ),
              const SizedBox(width: 6),
              Text('/ $total', style: mono(11, color: const Color(0x66FFFFFF))),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Stack(
              children: [
                Container(height: 4, color: const Color(0x1FFFFFFF)),
                FractionallySizedBox(
                  widthFactor: total == 0
                      ? 0
                      : (mapped / total).clamp(0.0, 1.0),
                  child: Container(height: 4, color: SR.blueBright),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            outstanding == 0
                ? 'Every facility has a verified pin.'
                : '$outstanding ${outstanding == 1 ? 'facility' : 'facilities'} '
                      'still ${outstanding == 1 ? 'needs' : 'need'} a verified '
                      'pin.',
            style: sans(10, height: 1.5, color: const Color(0x61FFFFFF)),
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
      ),
      child: Hoverable(
        builder: (context, hovered) => GestureDetector(
          onTap: () => onSelect(AppView.profile),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
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
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      admin.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(
                        12,
                        w: 500,
                        color: hovered ? SR.surface : const Color(0xE6FFFFFF),
                      ),
                    ),
                    Text(
                      'Registrar · ${admin.role.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(10, color: const Color(0x66FFFFFF)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
