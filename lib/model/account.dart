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

enum AccountAccessType {
  administrator('administrator', 'Administrator'),
  organizationRepresentative(
    'organization_representative',
    'Organization representative',
  ),
  externalGuest('external_guest', 'External guest'),
  legacyUnassigned('legacy_unassigned', 'Organization assignment required');

  const AccountAccessType(this.raw, this.label);

  final String raw;
  final String label;

  static AccountAccessType fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => AccountAccessType.legacyUnassigned,
  );
}

class OrganizationUnit {
  const OrganizationUnit({
    required this.id,
    this.parentId,
    required this.name,
    this.code,
    required this.unitType,
    this.active = true,
    this.requiresRepresentative = true,
    this.bookingAudience,
  });

  final String id;
  final String? parentId;
  final String name;
  final String? code;
  final String unitType;
  final bool active;
  final bool requiresRepresentative;
  final String? bookingAudience;

  String get label {
    final value = code == null || code!.isEmpty ? name : '$code · $name';
    return active ? value : '$value (disabled)';
  }

  String get policyLabel =>
      requiresRepresentative ? audienceLabel(bookingAudience) : 'Container';

  static String audienceLabel(String? audience) => switch (audience) {
    'student' => 'Student',
    'faculty' => 'Faculty',
    'staff' => 'University staff',
    _ => 'No booking audience',
  };
}

class OrganizationAccountSlot {
  const OrganizationAccountSlot({
    required this.id,
    required this.unitId,
    required this.label,
    this.active = true,
    this.assignedProfileId,
    this.assignedName,
    this.assignedEmail,
    this.unit,
  });

  final String id;
  final String unitId;
  final String label;
  final bool active;
  final String? assignedProfileId;
  final String? assignedName;
  final String? assignedEmail;
  final OrganizationUnit? unit;

  bool get assigned =>
      assignedProfileId != null && assignedProfileId!.isNotEmpty;

  String get occupancyLabel {
    if (!active) return 'Disabled';
    if (assigned) return 'Assigned';
    return 'Available';
  }
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
    this.organizationSlotId,
    this.organizationSlotLabel,
    this.organizationUnitId,
    this.organizationUnitName,
    this.organizationUnitCode,
    this.organizationUnitType,
    this.organizationUnitBookingAudience,
    this.accountAccessType = AccountAccessType.legacyUnassigned,
    this.mustChangePassword = false,
    this.passwordIssuedAt,
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
  final String? organizationSlotId;
  final String? organizationSlotLabel;
  final String? organizationUnitId;
  final String? organizationUnitName;
  final String? organizationUnitCode;
  final String? organizationUnitType;
  final String? organizationUnitBookingAudience;
  final AccountAccessType accountAccessType;
  final bool mustChangePassword;
  final DateTime? passwordIssuedAt;

  bool get hasOrganizationSlot =>
      organizationSlotId != null && organizationSlotId!.isNotEmpty;
  bool get isOrganizationRepresentative =>
      accountAccessType == AccountAccessType.organizationRepresentative;
  bool get isLegacyUnassigned =>
      accountAccessType == AccountAccessType.legacyUnassigned &&
      role == AccountRole.user;
  bool get isExternalGuest =>
      accountAccessType == AccountAccessType.externalGuest;

  String get organizationLabel {
    final name = organizationUnitName;
    final code = organizationUnitCode;
    if (name != null && name.isNotEmpty && code != null && code.isNotEmpty) {
      return '$code · $name';
    }
    if (name != null && name.isNotEmpty) return name;
    if (code != null && code.isNotEmpty) return code;
    return 'Unassigned campus account';
  }

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
    if (isOrganizationRepresentative) {
      return organizationUnitBookingAudience ?? 'student';
    }
    if (isExternalGuest || isLegacyUnassigned) return 'guest';
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
