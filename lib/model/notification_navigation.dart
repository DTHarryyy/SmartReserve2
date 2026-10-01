import 'package:flutter/foundation.dart';

enum NotificationDestination {
  adminReservation,
  feedback,
  anomalies,
  renterReservation,
  loyalty,
  browse,
  unavailable,
}

enum NotificationFocus {
  review,
  payment,
  extraTime,
  feedback,
  signature,
  permit,
  actions,
  attendance,
  details,
}

@immutable
class NotificationNavigationIntent {
  const NotificationNavigationIntent({
    required this.destination,
    required this.focus,
    required this.actionLabel,
    this.requestId,
    this.anomalyId,
    this.resourceId,
    this.openForm = false,
  });

  final NotificationDestination destination;
  final NotificationFocus focus;
  final String actionLabel;
  final String? requestId;
  final String? anomalyId;
  final String? resourceId;
  final bool openForm;
}

/// Converts the server's stable notification kinds into UI destinations.
/// Event details are used when a notification points at a child resource such
/// as a payment, occurrence, or time charge.
NotificationNavigationIntent resolveNotificationNavigation({
  required String kind,
  required bool isAdmin,
  String? requestId,
  String? anomalyId,
  Map<String, dynamic> eventDetails = const {},
}) {
  String? detailId(String key) {
    final value = eventDetails[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  if (isAdmin && kind.startsWith('anomaly_')) {
    return NotificationNavigationIntent(
      destination: NotificationDestination.anomalies,
      focus: NotificationFocus.details,
      actionLabel: 'Review alert',
      anomalyId: anomalyId,
    );
  }
  if (isAdmin && kind == 'feedback_low_rating') {
    return NotificationNavigationIntent(
      destination: NotificationDestination.feedback,
      focus: NotificationFocus.feedback,
      actionLabel: 'Review feedback',
      requestId: requestId,
      openForm: true,
    );
  }
  if (isAdmin && {'payment_submitted', 'payment_corrected'}.contains(kind)) {
    return NotificationNavigationIntent(
      destination: NotificationDestination.adminReservation,
      focus: NotificationFocus.payment,
      actionLabel: 'Review payment',
      requestId: requestId,
      resourceId: detailId('payment_id'),
    );
  }
  if (isAdmin &&
      {
        'reservation_extension_requested',
        'reservation_checked_out',
      }.contains(kind)) {
    return NotificationNavigationIntent(
      destination: NotificationDestination.adminReservation,
      focus: NotificationFocus.extraTime,
      actionLabel: kind == 'reservation_extension_requested'
          ? 'Review extension'
          : 'View checkout',
      requestId: requestId,
      resourceId: detailId('charge_id') ?? detailId('occurrence_id'),
    );
  }
  if (isAdmin && requestId != null) {
    return NotificationNavigationIntent(
      destination: NotificationDestination.adminReservation,
      focus: NotificationFocus.review,
      actionLabel: 'Review request',
      requestId: requestId,
      resourceId: detailId('occurrence_id'),
    );
  }

  if (!isAdmin && kind.startsWith('loyalty_')) {
    return const NotificationNavigationIntent(
      destination: NotificationDestination.loyalty,
      focus: NotificationFocus.details,
      actionLabel: 'View rewards',
    );
  }
  if (!isAdmin && kind.startsWith('new_facilit')) {
    return NotificationNavigationIntent(
      destination: NotificationDestination.browse,
      focus: NotificationFocus.details,
      actionLabel: 'Browse facilities',
      resourceId: detailId('facility_id'),
    );
  }
  if (!isAdmin && kind == 'signature_requested') {
    return NotificationNavigationIntent(
      destination: NotificationDestination.renterReservation,
      focus: NotificationFocus.signature,
      actionLabel: 'Sign now',
      requestId: requestId,
      openForm: true,
    );
  }
  if (!isAdmin && kind == 'payment_needs_correction') {
    return NotificationNavigationIntent(
      destination: NotificationDestination.renterReservation,
      focus: NotificationFocus.payment,
      actionLabel: 'Fix payment',
      requestId: requestId,
      resourceId: detailId('payment_id'),
      openForm: true,
    );
  }
  if (!isAdmin &&
      {
        'reservation_payment_instructions',
        'payment_reminder',
        'reservation_overtime_due',
      }.contains(kind)) {
    return NotificationNavigationIntent(
      destination: NotificationDestination.renterReservation,
      focus: NotificationFocus.payment,
      actionLabel: 'Pay now',
      requestId: requestId,
      openForm: true,
    );
  }
  if (!isAdmin &&
      {
        'permit_available',
        'permit_voided',
        'signature_submitted',
      }.contains(kind)) {
    return NotificationNavigationIntent(
      destination: NotificationDestination.renterReservation,
      focus: NotificationFocus.permit,
      actionLabel: kind == 'permit_available' ? 'View permit' : 'View details',
      requestId: requestId,
      openForm: kind == 'permit_available',
    );
  }
  if (!isAdmin &&
      {'feedback_reply', 'reservation_use_assessment'}.contains(kind)) {
    return NotificationNavigationIntent(
      destination: NotificationDestination.renterReservation,
      focus: NotificationFocus.feedback,
      actionLabel: 'View feedback',
      requestId: requestId,
    );
  }
  if (!isAdmin &&
      {
        'reservation_request_changes',
        'reservation_changed',
        'reservation_bumped',
        'facility_maintenance',
      }.contains(kind)) {
    return NotificationNavigationIntent(
      destination: NotificationDestination.renterReservation,
      focus: NotificationFocus.actions,
      actionLabel: 'Review changes',
      requestId: requestId,
      resourceId: detailId('occurrence_id'),
    );
  }
  if (!isAdmin &&
      {'reservation_reminder', 'reservation_self_check_in'}.contains(kind)) {
    return NotificationNavigationIntent(
      destination: NotificationDestination.renterReservation,
      focus: NotificationFocus.attendance,
      actionLabel: 'View booking',
      requestId: requestId,
      resourceId: detailId('occurrence_id'),
    );
  }
  if (!isAdmin && requestId != null) {
    return NotificationNavigationIntent(
      destination: NotificationDestination.renterReservation,
      focus: NotificationFocus.details,
      actionLabel: 'View details',
      requestId: requestId,
      resourceId: detailId('occurrence_id'),
    );
  }

  return const NotificationNavigationIntent(
    destination: NotificationDestination.unavailable,
    focus: NotificationFocus.details,
    actionLabel: 'View details',
  );
}
