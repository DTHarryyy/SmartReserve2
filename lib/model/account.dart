import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';

enum VerificationState {
  verified('verified', 'Verified', SR.greenTint, SR.greenDark),
  pending('pending', 'Awaiting review', SR.amberTint, SR.amber),
  rejected('rejected', 'Not verified', SR.redTint, SR.red),
  none('none', 'Guest', SR.dividerSoft, SR.ink4);

  const VerificationState(
    this.raw,
    this.label,
    this.background,
    this.foreground,
  );

  final String raw;
  final String label;
  final Color background;
  final Color foreground;

  static VerificationState fromRaw(String raw) => values.firstWhere(
    (v) => v.raw == raw,
    orElse: () => VerificationState.none,
  );
}

enum AccountStatus {
  active('active', 'Active', SR.greenTint, SR.greenDark),
  suspended('suspended', 'Suspended', SR.redTint, SR.red),
  invited('invited', 'Invited', SR.amberTint, SR.amber);

  const AccountStatus(this.raw, this.label, this.background, this.foreground);

  final String raw;
  final String label;
  final Color background;
  final Color foreground;

  static AccountStatus fromRaw(String raw) => values.firstWhere(
    (s) => s.raw == raw,
    orElse: () => AccountStatus.active,
  );
}

enum AccountRole {
  student('Student'),
  faculty('Faculty'),
  staff('University staff'),
  guest('Guest'),
  internalAdmin('Internal admin'),
  externalAdmin('External admin');

  const AccountRole(this.label);

  final String label;

  bool get isAdmin =>
      this == AccountRole.internalAdmin || this == AccountRole.externalAdmin;

  String get privileges => switch (this) {
    AccountRole.student || AccountRole.faculty || AccountRole.staff =>
      'Reserves free once verified · needs approval · may book a recurring '
          'series · gets priority when two requests collide.',
    AccountRole.guest =>
      'Reserves at the published external rate · pays before the slot is held '
          '· no recurring series · longer advance-booking window for planning.',
    AccountRole.internalAdmin =>
      'Manages facilities, decides reservations, approves campus '
          'verifications, and manages accounts. Sees student documents.',
    AccountRole.externalAdmin =>
      'Manages external clients, rates, quotes, invoices and refunds, and '
          'their bookings only.',
  };

  static AccountRole fromLabel(String label) => values.firstWhere(
    (r) => r.label == label,
    orElse: () => AccountRole.guest,
  );

  static AccountRole fromRaw(String raw) => switch (raw) {
    'student' => AccountRole.student,
    'faculty' => AccountRole.faculty,
    'staff' => AccountRole.staff,
    'internal_admin' => AccountRole.internalAdmin,
    'external_admin' => AccountRole.externalAdmin,
    _ => AccountRole.guest,
  };
}

class Account {
  Account({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.unit,
    required this.idNumber,
    required this.verification,
    required this.status,
    required this.reservations,
    required this.lastActive,
    required this.joined,
    required this.noShows,
    this.isSelf = false,
    this.suspendUntil,
    this.suspendReason,
    this.inviteExpires,
    this.invitationSentAt,
    this.lastActiveAt,
    this.joinedAt,
    this.activityMetricsAvailable = true,
  });

  final String id;
  String name;
  String email;
  AccountRole role;
  String unit;
  String idNumber;
  VerificationState verification;
  AccountStatus status;
  int reservations;
  String lastActive;
  String joined;
  int noShows;

  final bool isSelf;

  String? suspendUntil;
  String? suspendReason;
  String? inviteExpires;
  DateTime? invitationSentAt;
  DateTime? lastActiveAt;
  DateTime? joinedAt;
  final bool activityMetricsAvailable;

  String get initials {
    final words = name
        .replaceAll(RegExp(r'[^A-Za-z. ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return email.substring(0, 2).toUpperCase();
    if (words.length == 1) {
      return words.first.substring(0, 2).toUpperCase();
    }
    return (words.first[0] + words[1][0]).toUpperCase();
  }

  bool get isInvited => status == AccountStatus.invited;

  bool get reservesFree =>
      !role.isAdmin &&
      (verification == VerificationState.verified ||
          verification == VerificationState.pending);
}
