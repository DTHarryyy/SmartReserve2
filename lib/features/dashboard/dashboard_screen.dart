import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../app/app_view.dart';
import '../../model/payment.dart';
import '../../model/reservation.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';

/// Admin landing page: live counts that link into their queues, one-tap
/// shortcuts to the common tasks, and what is happening on campus today.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, this.onNewFacility});

  /// Opens the facility editor on a blank record (owned by the shell).
  final VoidCallback? onNewFacility;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final today = dashboardTodayBookings(state);

    return SrScrollView(
      padding: SR.pageInsets(width, bottom: SR.space32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: SR.contentMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SrPageHeader(
                eyebrow: 'Welcome back',
                title: state.currentAdmin.name,
                description:
                    'Everything that needs you today, one tap from here.',
              ),
              const SizedBox(height: SR.space20),
              _KpiGrid(state: state, todayCount: today.length),
              const SizedBox(height: SR.space24),
              const SrSectionHeader(
                title: 'Shortcuts',
                icon: Icons.bolt_rounded,
              ),
              _Shortcuts(state: state, onNewFacility: onNewFacility),
              const SizedBox(height: SR.space24),
              LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= SR.contentWide;
                  final schedule = _TodaySchedule(state: state, today: today);
                  final inbox = _UnreadNotifications(state: state);
                  if (!wide) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        schedule,
                        const SizedBox(height: SR.space20),
                        inbox,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: schedule),
                      const SizedBox(width: SR.space20),
                      Expanded(child: inbox),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Booked occurrences that start today (campus time), earliest first.
List<({ReservationRequest request, ReservationOccurrence occurrence})>
dashboardTodayBookings(AppState state) {
  final now = campusNow();
  final rows = [
    for (final request in state.requests)
      if (request.status == RequestStatus.approved)
        for (final occurrence in request.occurrences)
          if (occurrence.isBooked &&
              _sameDay(campusWallTime(occurrence.startsAt), now))
            (request: request, occurrence: occurrence),
  ]..sort((a, b) => a.occurrence.startsAt.compareTo(b.occurrence.startsAt));
  return rows;
}

/// Payment proofs waiting for an administrator to verify or reject.
int dashboardPaymentsToReview(AppState state) => state.requests
    .expand((request) => request.paymentTransactions)
    .where((payment) => payment.status == PaymentDecisionStatus.submitted)
    .length;

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.state, required this.todayCount});

  final AppState state;
  final int todayCount;

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      _KpiTile(
        key: const Key('dashboard-kpi-pending'),
        label: 'Pending requests',
        value: state.pendingRequests,
        icon: Icons.pending_actions_rounded,
        tone: state.pendingRequests > 0 ? SrTone.warning : SrTone.neutral,
        onTap: () => state.goTo(AppView.reservations),
      ),
      _KpiTile(
        key: const Key('dashboard-kpi-payments'),
        label: 'Payments to review',
        value: dashboardPaymentsToReview(state),
        icon: Icons.receipt_long_rounded,
        tone: dashboardPaymentsToReview(state) > 0
            ? SrTone.info
            : SrTone.neutral,
        onTap: () => state.goTo(AppView.reservations),
      ),
      _KpiTile(
        key: const Key('dashboard-kpi-today'),
        label: 'Bookings today',
        value: todayCount,
        icon: Icons.event_available_rounded,
        tone: SrTone.brand,
        onTap: () {
          state.goToCalendarToday();
          state.goTo(AppView.calendar);
        },
      ),
      _KpiTile(
        key: const Key('dashboard-kpi-anomalies'),
        label: 'High-risk anomalies',
        value: state.anomalyActiveHighCriticalCount,
        icon: Icons.shield_moon_rounded,
        tone: state.anomalyActiveHighCriticalCount > 0
            ? SrTone.error
            : SrTone.neutral,
        onTap: () => state.goTo(AppView.anomalies),
      ),
      _KpiTile(
        key: const Key('dashboard-kpi-notifications'),
        label: 'Unread notifications',
        value: state.unreadNotifications,
        icon: Icons.notifications_none_rounded,
        tone: SrTone.neutral,
        onTap: state.toggleNotifications,
      ),
      _KpiTile(
        key: const Key('dashboard-kpi-mapped'),
        label: 'Facilities mapped',
        value: state.mappedCount,
        suffix: '/ ${state.catalogueTotal}',
        icon: Icons.apartment_rounded,
        tone: SrTone.neutral,
        onTap: () => state.goTo(AppView.facilities),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= SR.contentWide
            ? 3
            : constraints.maxWidth >= SR.contentNarrow
            ? 2
            : 1;
        const gap = SR.space12;
        final tileWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final tile in tiles) SizedBox(width: tileWidth, child: tile),
          ],
        );
      },
    );
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.tone,
    required this.onTap,
    this.suffix,
  });

  final String label;
  final int value;
  final String? suffix;
  final IconData icon;
  final SrTone tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.srColors;
    return Semantics(
      button: true,
      label: '$label: $value',
      child: SrCard(
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: SR.controlMd,
              height: SR.controlMd,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tone == SrTone.neutral ? c.surfaceSubtle : tone.tint,
                borderRadius: BorderRadius.circular(SR.rMd),
              ),
              child: Icon(
                icon,
                size: SR.iconMd,
                color: tone == SrTone.neutral ? c.ink3 : tone.ink,
              ),
            ),
            const SizedBox(width: SR.space12),
            Expanded(
              child: SrStat(
                label: label,
                value: suffix == null ? '$value' : '$value $suffix',
                tone: value == 0 ? SrTone.neutral : tone,
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: SR.iconMd, color: c.muted),
          ],
        ),
      ),
    );
  }
}

class _Shortcuts extends StatelessWidget {
  const _Shortcuts({required this.state, this.onNewFacility});

  final AppState state;
  final VoidCallback? onNewFacility;

  @override
  Widget build(BuildContext context) {
    final actions = <({String label, IconData icon, VoidCallback onTap})>[
      if (onNewFacility != null)
        (
          label: 'New facility',
          icon: Icons.add_business_rounded,
          onTap: onNewFacility!,
        ),
      (
        label: 'Review requests',
        icon: Icons.pending_actions_rounded,
        onTap: () => state.goTo(AppView.reservations),
      ),
      (
        label: 'Calendar',
        icon: Icons.calendar_month_rounded,
        onTap: () => state.goTo(AppView.calendar),
      ),
      (
        label: 'Feedback',
        icon: Icons.reviews_rounded,
        onTap: () => state.goTo(AppView.feedback),
      ),
      (
        label: 'Reports',
        icon: Icons.insights_rounded,
        onTap: () => state.goTo(AppView.reports),
      ),
      if (state.isInternalAdmin) ...[
        (
          label: 'Users',
          icon: Icons.people_alt_rounded,
          onTap: () => state.goTo(AppView.users),
        ),
        (
          label: 'Organizations',
          icon: Icons.account_tree_rounded,
          onTap: () => state.goTo(AppView.organizations),
        ),
      ],
      if (state.isExternalAdmin) ...[
        (
          label: 'Clients',
          icon: Icons.people_alt_rounded,
          onTap: () => state.goTo(AppView.users),
        ),
        (
          label: 'Loyalty',
          icon: Icons.stars_rounded,
          onTap: () => state.goTo(AppView.loyalty),
        ),
      ],
      (
        label: 'Backups',
        icon: Icons.backup_rounded,
        onTap: () => state.goTo(AppView.backups),
      ),
    ];
    return Wrap(
      spacing: SR.space8,
      runSpacing: SR.space8,
      children: [
        for (final action in actions)
          SrButton(
            key: ValueKey('dashboard-shortcut-${action.label}'),
            label: action.label,
            icon: Icon(action.icon, size: SR.iconMd),
            onPressed: action.onTap,
          ),
      ],
    );
  }
}

class _TodaySchedule extends StatelessWidget {
  const _TodaySchedule({required this.state, required this.today});

  final AppState state;
  final List<({ReservationRequest request, ReservationOccurrence occurrence})>
  today;

  static String _clock(DateTime value) {
    final local = campusWallTime(value);
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${local.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) => SrListGroup(
    title: 'Today on campus',
    footnote: today.isEmpty ? 'No booked reservations today.' : null,
    children: [
      for (final row in today.take(6))
        SrListRow(
          icon: Icons.schedule_rounded,
          label: row.request.facility,
          value:
              '${_clock(row.occurrence.startsAt)} – '
              '${_clock(row.occurrence.endsAt)} · ${row.request.requester}',
          onTap: () {
            state.selectRequest(row.request.id);
            state.goTo(AppView.reservations);
          },
        ),
      if (today.isEmpty)
        const SrListRow(
          icon: Icons.event_busy_rounded,
          label: 'Nothing scheduled',
        ),
    ],
  );
}

class _UnreadNotifications extends StatelessWidget {
  const _UnreadNotifications({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => SrListGroup(
    title: 'Unread notifications',
    children: [
      for (final notification in state.notifications.take(5))
        SrListRow(
          icon: Icons.notifications_active_outlined,
          label: notification.title,
          value: notification.body,
          onTap: () => state.openNotification(notification),
        ),
      if (state.notifications.isEmpty)
        const SrListRow(
          icon: Icons.done_all_rounded,
          label: 'You are all caught up',
        ),
    ],
  );
}
