import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../backend/supabase_service.dart';
import '../model/notification_navigation.dart';
import '../theme/sr_theme.dart';
import '../theme/sr_tokens.dart';
import 'sr_controls.dart';

class NotificationInbox extends StatelessWidget {
  const NotificationInbox({
    super.key,
    required this.state,
    this.mobile = false,
    this.onClose,
  });

  final AppState state;
  final bool mobile;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.srColors;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: BorderRadius.circular(mobile ? SR.rLg : SR.rMd),
          border: Border.all(color: colors.border),
          boxShadow: mobile ? null : SR.popoverShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(state: state, mobile: mobile, onClose: onClose),
            Divider(height: 1, color: colors.hairline),
            Flexible(
              child: AnimatedSwitcher(
                duration: reduceMotion ? Duration.zero : SR.stateChange,
                child: _body(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (state.notificationsLoading && state.notifications.isEmpty) {
      return const _NotificationSkeleton(key: ValueKey('notification-loading'));
    }
    if (state.notificationsError case final error?
        when state.notifications.isEmpty) {
      return _NotificationError(
        key: const ValueKey('notification-error'),
        message: error,
        onRetry: state.refreshNotifications,
      );
    }
    if (state.notifications.isEmpty) {
      return const _NotificationEmpty(key: ValueKey('notification-empty'));
    }
    return ListView.separated(
      key: ValueKey(
        state.notifications.map((notification) => notification.id).join('|'),
      ),
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: state.notifications.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, indent: 72, color: context.srColors.hairline),
      itemBuilder: (context, index) {
        final notification = state.notifications[index];
        final intent = resolveNotificationNavigation(
          kind: notification.kind,
          isAdmin: state.isAdmin,
          requestId: notification.requestId,
          anomalyId: notification.anomalyId,
          eventDetails: notification.eventDetails,
        );
        return _NotificationRow(
          notification: notification,
          actionLabel: intent.actionLabel,
          busy: state.notificationActionsPending.contains(notification.id),
          onTap: () {
            onClose?.call();
            state.openNotification(notification);
          },
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.state,
    required this.mobile,
    required this.onClose,
  });

  final AppState state;
  final bool mobile;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(18, mobile ? 8 : 16, 10, 14),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mobile) ...[
          Container(
            key: const Key('notification-drag-handle'),
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: context.srColors.borderStrong,
              borderRadius: BorderRadius.circular(SR.rFull),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: context.srColors.infoContainer,
                borderRadius: BorderRadius.circular(SR.rSm),
              ),
              child: Icon(
                Icons.notifications_none_rounded,
                size: 20,
                color: context.srColors.brand,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(child: Text('Notifications', style: SrType.subhead())),
            if (state.unreadNotifications > 0)
              Container(
                constraints: const BoxConstraints(minWidth: 26),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: context.srColors.brandContainer,
                  borderRadius: BorderRadius.circular(SR.rFull),
                ),
                child: Text(
                  state.unreadNotifications > 99
                      ? '99+'
                      : '${state.unreadNotifications}',
                  textAlign: TextAlign.center,
                  style: mono(10.5, w: 600, color: context.srColors.brand),
                ),
              ),
            if (mobile) ...[
              const SizedBox(width: 6),
              SrIconButton(
                icon: Icons.close_rounded,
                tooltip: 'Close notifications',
                size: 44,
                onPressed: onClose,
              ),
            ],
          ],
        ),
      ],
    ),
  );
}

enum _NotificationTone { info, attention, danger, success }

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({
    required this.notification,
    required this.actionLabel,
    required this.busy,
    required this.onTap,
  });

  final BackendNotification notification;
  final String actionLabel;
  final bool busy;
  final VoidCallback onTap;

  _NotificationTone get _tone {
    final kind = notification.kind;
    if (kind.startsWith('anomaly_') || kind == 'feedback_low_rating') {
      return _NotificationTone.danger;
    }
    if (kind.startsWith('payment_') ||
        kind.contains('payment') ||
        kind.startsWith('signature_') ||
        kind.contains('request_changes') ||
        kind == 'reservation_changed' ||
        kind.contains('bumped')) {
      return _NotificationTone.attention;
    }
    if (kind.startsWith('loyalty_') ||
        kind == 'permit_available' ||
        kind.contains('approved') ||
        kind.contains('complete') ||
        kind == 'payment_verify') {
      return _NotificationTone.success;
    }
    return _NotificationTone.info;
  }

  IconData get _icon => switch (_tone) {
    _NotificationTone.danger => Icons.warning_amber_rounded,
    _NotificationTone.attention =>
      notification.kind.contains('payment')
          ? Icons.payments_outlined
          : Icons.edit_notifications_outlined,
    _NotificationTone.success =>
      notification.kind.startsWith('loyalty_')
          ? Icons.stars_rounded
          : Icons.task_alt_rounded,
    _NotificationTone.info => Icons.event_note_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.srColors;
    final (foreground, background) = switch (_tone) {
      _NotificationTone.info => (colors.info, colors.infoContainer),
      _NotificationTone.attention => (
        colors.amberTitle,
        colors.warningContainer,
      ),
      _NotificationTone.danger => (colors.error, colors.errorContainer),
      _NotificationTone.success => (colors.success, colors.successContainer),
    };
    final relative = _relativeTime(notification.createdAt);
    final absolute = MaterialLocalizations.of(
      context,
    ).formatFullDate(notification.createdAt.toLocal());

    return Semantics(
      button: true,
      label:
          '${notification.title}. ${notification.body}. $relative. $actionLabel.',
      child: InkWell(
        onTap: busy ? null : onTap,
        focusColor: colors.focus.withValues(alpha: .12),
        hoverColor: colors.surfaceSubtle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: background,
                      borderRadius: BorderRadius.circular(SR.rSm),
                    ),
                    child: Icon(_icon, size: 20, color: foreground),
                  ),
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: colors.brand,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colors.surfaceElevated,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notification.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: SrType.bodySm(w: 600, color: colors.text),
                    ),
                    if (notification.body.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        notification.body,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: SrType.bodySm(color: colors.textSecondary),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Tooltip(
                          message:
                              '$absolute · ${TimeOfDay.fromDateTime(notification.createdAt.toLocal()).format(context)}',
                          child: Text(
                            relative,
                            style: SrType.caption(color: colors.textMuted),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          busy ? 'Opening…' : actionLabel,
                          style: SrType.caption(color: colors.brand, w: 600),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 17,
                          color: colors.brand,
                        ),
                      ],
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

class _NotificationSkeleton extends StatelessWidget {
  const _NotificationSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [for (var i = 0; i < 3; i++) const _SkeletonRow()],
  );
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        _bar(context, width: 40, height: 40, radius: SR.rSm),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _bar(context, width: 170, height: 12),
              const SizedBox(height: 9),
              _bar(context, width: double.infinity, height: 10),
              const SizedBox(height: 7),
              _bar(context, width: 88, height: 9),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _bar(
    BuildContext context, {
    required double width,
    required double height,
    double radius = 4,
  }) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: context.srColors.surfaceSunken,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

class _NotificationEmpty extends StatelessWidget {
  const _NotificationEmpty({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 42),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.task_alt_rounded, size: 34, color: context.srColors.success),
        const SizedBox(height: 12),
        Text('You’re all caught up', style: SrType.body(w: 600)),
        const SizedBox(height: 4),
        Text(
          'New updates and actions will appear here.',
          textAlign: TextAlign.center,
          style: SrType.bodySm(color: context.srColors.textMuted),
        ),
      ],
    ),
  );
}

class _NotificationError extends StatelessWidget {
  const _NotificationError({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.cloud_off_outlined, color: context.srColors.error),
        const SizedBox(height: 10),
        Text(
          'Notifications could not be loaded.',
          style: SrType.bodySm(w: 600),
        ),
        const SizedBox(height: 4),
        Text(
          message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: SrType.caption(color: context.srColors.textMuted),
        ),
        const SizedBox(height: 12),
        SrButton(label: 'Try again', dense: true, onPressed: onRetry),
      ],
    ),
  );
}

String _relativeTime(DateTime value, [DateTime? now]) {
  final difference = (now ?? DateTime.now()).difference(value.toLocal());
  if (difference.isNegative || difference.inMinutes < 1) return 'Just now';
  if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
  if (difference.inHours < 24) return '${difference.inHours}h ago';
  if (difference.inDays < 7) return '${difference.inDays}d ago';
  return '${value.toLocal().month}/${value.toLocal().day}/${value.toLocal().year}';
}
