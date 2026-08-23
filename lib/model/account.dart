import 'package:flutter/material.dart';

import '../theme/sr_tokens.dart';

enum VerificationState {
  verified('verified', 'Verified', SrTone.success),
  pending('pending', 'Awaiting review', SrTone.warning),
  rejected('rejected', 'Not verified', SrTone.error),
  none('none', 'Guest', SrTone.neutral);

  const VerificationState(this.raw, this.label, this.tone);

  final String raw;
  final String label;
  final SrTone tone;

  Color get background => tone.tint;
  Color get foreground => tone.ink;

  static VerificationState fromRaw(String raw) => values.firstWhere(
    (v) => v.raw == raw,
    orElse: () => VerificationState.none,
  );
}

enum AccountStatus {
  active('active', 'Active', SrTone.success),
  suspended('suspended', 'Suspended', SrTone.error),
  invited('invited', 'Invited', SrTone.warning);

  const AccountStatus(this.raw, this.label, this.tone);

  final String raw;
  final String label;
  final SrTone tone;

  Color get background => tone.tint;
  Color get foreground => tone.ink;

  static AccountStatus fromRaw(String raw) => values.firstWhere(
    (s) => s.raw == raw,
    orElse: () => AccountStatus.active,
  );
}

enum AccountRole {
  user('User'),
  internalAdmin('Internal admin'),
  externalAdmin('External admin');

  const AccountRole(this.label);

  final String label;

  bool get isAdmin =>
      this == AccountRole.internalAdmin || this == AccountRole.externalAdmin;

  String get privileges => switch (this) {
    AccountRole.user =>
      'Books facilities that have an administrator for the account’s '
          'verification lane · uses the facility’s published audience rate.',
    AccountRole.internalAdmin =>
      'Manages assigned facilities and verified-user reservations · reviews '
          'campus verification and governs accounts.',
    AccountRole.externalAdmin =>
      'Manages assigned facilities, payments, schedules, and guest or '
          'unverified-user reservations.',
  };

  static AccountRole fromLabel(String label) => values.firstWhere(
    (r) => r.label == label,
    orElse: () => throw ArgumentError.value(label, 'label', 'Unknown role'),
  );

  static AccountRole fromRaw(String raw) => switch (raw) {
    'user' => AccountRole.user,
    'internal_admin' => AccountRole.internalAdmin,
    'external_admin' => AccountRole.externalAdmin,
    _ => throw ArgumentError.value(raw, 'raw', 'Unknown account role'),
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

  String get pricingAudience {
    if (verification != VerificationState.verified) return 'guest';
    final normalized = unit.toLowerCase();
    if (normalized.contains('faculty')) return 'faculty';
    if (normalized.contains('staff')) return 'staff';
    return 'student';
  }

  /// Verified students and faculty pay nothing (staff is not exempt). This
  /// mirrors the authoritative database rule for the demo/offline preview
  /// only -- production exemption always comes from the server quote.
  bool get isPaymentExempt {
    final audience = pricingAudience;
    return audience == 'student' || audience == 'faculty';
  }

  /// Compatibility-only display hint for old fixtures. Production pricing and
  /// authorization never read this value; both come from the server quote.
  @Deprecated('Use the facility audience rate returned by the server quote.')
  bool get reservesFree =>
      role == AccountRole.user &&
      status == AccountStatus.active &&
      verification == VerificationState.verified;
}
