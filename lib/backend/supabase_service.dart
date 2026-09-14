// ignore_for_file: annotate_overrides

import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/rendering.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/campus_data.dart';
import '../model/facility.dart';
import '../model/facility_draft.dart';
import '../model/facility_photo.dart';
import '../model/payment.dart';
import '../model/permit.dart';
import '../features/reports/reports_data.dart';
import '../model/audit_entry.dart';
import '../model/anomaly.dart';
import '../model/feedback.dart';
import '../model/loyalty.dart';
import '../util/geo.dart';

class AccountManagementException implements Exception {
  const AccountManagementException({
    required this.code,
    required this.message,
    required this.status,
    this.requestId,
  });

  factory AccountManagementException.fromFunctionException(
    FunctionException error,
  ) {
    final details = _accountErrorDetails(error.details);
    final rawCode = details['code'];
    final code = rawCode is String ? rawCode : _accountErrorCode(error.status);
    final rawMessage = details['error'];
    final message = rawMessage is String
        ? rawMessage
        : _accountErrorMessage(code, error.status);
    final rawRequestId = details['request_id'];
    return AccountManagementException(
      code: code,
      message: message,
      status: error.status,
      requestId: rawRequestId is String ? rawRequestId : null,
    );
  }

  const AccountManagementException.invalidResponse({this.status = 0})
    : code = 'invalid_response',
      message = 'User management returned an invalid response.',
      requestId = null;

  final String code;
  final String message;
  final int status;
  final String? requestId;

  bool get isRetryable =>
      code == 'network' || code == 'rate_limited' || code == 'server_error';

  @override
  String toString() => message;
}

Map<String, dynamic> _accountErrorDetails(dynamic details) {
  if (details is Map) return Map<String, dynamic>.from(details);
  if (details is String) {
    try {
      final decoded = jsonDecode(details);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException {
      debugPrint('Failed to decode account error details: $details');
    }
  }
  return const {};
}

String _accountErrorCode(int status) => switch (status) {
  0 => 'network',
  400 => 'invalid_request',
  401 => 'unauthorized',
  403 => 'forbidden',
  404 => 'not_found',
  409 => 'conflict',
  429 => 'rate_limited',
  >= 500 => 'server_error',
  _ => 'request_failed',
};

String _accountErrorMessage(String code, int status) => switch (code) {
  'network' => 'SmartReserve could not be reached.',
  'unauthorized' => 'Your session is no longer valid.',
  'forbidden' => 'You do not have permission to manage accounts.',
  'not_found' => 'Account not found.',
  'rate_limited' => 'Too many requests. Wait a moment and try again.',
  'server_error' => 'User management is temporarily unavailable.',
  'invalid_request' => 'The account action was not valid.',
  _ => 'User management request failed (HTTP $status).',
};

class SessionProfile {
  const SessionProfile({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
    required this.campusClaim,
    required this.campusId,
    required this.unit,
    required this.verificationStatus,
    required this.onboardingComplete,
    required this.accountStatus,
    required this.accountAccessType,
    required this.mustChangePassword,
    required this.createdAt,
    this.passwordIssuedAt,
    this.suspensionReason,
    this.suspendedUntil,
    this.organizationSlotId,
    this.organizationSlotLabel,
    this.organizationUnitId,
    this.organizationUnitName,
    this.organizationUnitCode,
    this.organizationUnitType,
    this.organizationUnitBookingAudience,
  });

  final String id;
  final String email;
  final String fullName;
  final String role;
  final String? campusClaim;
  final String? campusId;
  final String? unit;
  final String verificationStatus;
  final bool onboardingComplete;
  final String accountStatus;
  final String accountAccessType;
  final bool mustChangePassword;
  final DateTime? createdAt;
  final DateTime? passwordIssuedAt;
  final String? suspensionReason;
  final DateTime? suspendedUntil;
  final String? organizationSlotId;
  final String? organizationSlotLabel;
  final String? organizationUnitId;
  final String? organizationUnitName;
  final String? organizationUnitCode;
  final String? organizationUnitType;
  final String? organizationUnitBookingAudience;

  bool get isActive => accountStatus == 'active';
  bool get isInternalAdmin => role == 'internal_admin' && isActive;
  bool get isExternalAdmin => role == 'external_admin' && isActive;
  bool get isAdmin => isInternalAdmin || isExternalAdmin;
  bool get isOrganizationRepresentative =>
      accountAccessType == 'organization_representative' && isActive;

  factory SessionProfile.fromJson(Map<String, dynamic> json) => SessionProfile(
    id: json['id'] as String,
    email: (json['email'] as String?) ?? '',
    fullName: (json['full_name'] as String?) ?? '',
    role: _accountRole(json['role']),
    campusClaim: json['campus_claim'] as String?,
    campusId: json['campus_id'] as String?,
    unit: json['unit'] as String?,
    verificationStatus: (json['verification_status'] as String?) ?? 'none',
    onboardingComplete: (json['onboarding_complete'] as bool?) ?? false,
    accountStatus: (json['account_status'] as String?) ?? 'active',
    accountAccessType:
        (json['account_access_type'] as String?) ?? 'legacy_unassigned',
    mustChangePassword: (json['must_change_password'] as bool?) ?? false,
    createdAt: DateTime.tryParse((json['created_at'] as String?) ?? ''),
    passwordIssuedAt: DateTime.tryParse(
      (json['password_issued_at'] as String?) ?? '',
    ),
    suspensionReason: json['suspension_reason'] as String?,
    suspendedUntil: DateTime.tryParse(
      (json['suspended_until'] as String?) ?? '',
    ),
    organizationSlotId: json['organization_slot_id'] as String?,
    organizationSlotLabel: json['organization_slot_label'] as String?,
    organizationUnitId: json['organization_unit_id'] as String?,
    organizationUnitName: json['organization_unit_name'] as String?,
    organizationUnitCode: json['organization_unit_code'] as String?,
    organizationUnitType: json['organization_unit_type'] as String?,
    organizationUnitBookingAudience:
        json['organization_unit_booking_audience'] as String?,
  );
}

/// A sanitized failure from the authentication and session-profile handshake.
///
/// The fields are for development diagnostics only. UI code must map [kind] to
/// a fixed message rather than displaying an exception returned by Supabase.
enum AuthFailureKind {
  invalidCredentials,
  samePassword,
  weakPassword,
  passwordReauthenticationRequired,
  recoveryCodeExpired,
  recoveryCodeInvalid,
  sessionExpired,
  emailUnconfirmed,
  emailConfirmationRequired,
  emailAlreadyRegistered,
  rateLimited,
  network,
  profileMissing,
  profileContractUnavailable,
  profileAccessDenied,
  unknown,
}

class AuthSessionException implements Exception {
  const AuthSessionException({
    required this.kind,
    this.statusCode,
    this.backendCode,
    this.cause,
  });

  final AuthFailureKind kind;
  final String? statusCode;
  final String? backendCode;
  final Object? cause;

  @override
  String toString() => 'Auth session failure: ${kind.name}';
}

const _profileContractErrorCodes = <String>{
  // PostgREST cannot resolve an embedded relationship, RPC, or table from its
  // schema cache. These are deployment/schema failures, not user failures.
  'PGRST200',
  'PGRST201',
  'PGRST202',
  'PGRST205',
  // PostgreSQL undefined column, table, and function errors respectively.
  '42703',
  '42P01',
  '42883',
};

bool _isProfileContractError(PostgrestException error) =>
    _profileContractErrorCodes.contains(error.code);

AuthSessionException _profileContractFailure(Object cause, {String? code}) =>
    AuthSessionException(
      kind: AuthFailureKind.profileContractUnavailable,
      backendCode: code,
      cause: cause,
    );

AuthSessionException classifyAuthFailure(Object error) {
  if (error is AuthSessionException) return error;

  if (error is AccountManagementException) {
    final kind = switch (error.code.toLowerCase()) {
      'same_password' => AuthFailureKind.samePassword,
      'weak_password' => AuthFailureKind.weakPassword,
      'reauthentication_needed' || 'reauthentication_not_valid' =>
        AuthFailureKind.passwordReauthenticationRequired,
      'unauthorized' ||
      'session_expired' ||
      'session_missing' ||
      'session_not_found' => AuthFailureKind.sessionExpired,
      'rate_limited' => AuthFailureKind.rateLimited,
      _ => AuthFailureKind.unknown,
    };
    return AuthSessionException(
      kind: kind,
      statusCode: '${error.status}',
      backendCode: error.code,
      cause: error,
    );
  }

  if (error is AuthException) {
    final message = error.message.toLowerCase();
    final status = error.statusCode?.toString() ?? '';
    final code = error.code?.toLowerCase() ?? '';
    if (code == 'same_password' ||
        message.contains('different from the old password') ||
        message.contains('same password')) {
      return AuthSessionException(
        kind: AuthFailureKind.samePassword,
        statusCode: status,
        backendCode: error.code,
        cause: error,
      );
    }
    if (code == 'weak_password' || message.contains('weak password')) {
      return AuthSessionException(
        kind: AuthFailureKind.weakPassword,
        statusCode: status,
        backendCode: error.code,
        cause: error,
      );
    }
    if (code == 'reauthentication_needed' ||
        code == 'reauthentication_not_valid') {
      return AuthSessionException(
        kind: AuthFailureKind.passwordReauthenticationRequired,
        statusCode: status,
        backendCode: error.code,
        cause: error,
      );
    }
    if (code == 'otp_expired' || code == 'flow_state_expired') {
      return AuthSessionException(
        kind: AuthFailureKind.recoveryCodeExpired,
        statusCode: status,
        backendCode: error.code,
        cause: error,
      );
    }
    if (code == 'flow_state_not_found' ||
        message.contains('token has expired or is invalid') ||
        message.contains('invalid otp')) {
      return AuthSessionException(
        kind: AuthFailureKind.recoveryCodeInvalid,
        statusCode: status,
        backendCode: error.code,
        cause: error,
      );
    }
    if (code == 'session_expired' ||
        code == 'session_missing' ||
        code == 'session_not_found') {
      return AuthSessionException(
        kind: AuthFailureKind.sessionExpired,
        statusCode: status,
        backendCode: error.code,
        cause: error,
      );
    }
    if (status == '429' ||
        code.startsWith('over_') && code.endsWith('_rate_limit') ||
        message.contains('rate limit')) {
      return AuthSessionException(
        kind: AuthFailureKind.rateLimited,
        statusCode: status,
        backendCode: error.code,
        cause: error,
      );
    }
    if (message.contains('invalid login credentials') ||
        message.contains('invalid credentials')) {
      return AuthSessionException(
        kind: AuthFailureKind.invalidCredentials,
        statusCode: status,
        backendCode: error.code,
        cause: error,
      );
    }
    if (message.contains('email not confirmed')) {
      return AuthSessionException(
        kind: AuthFailureKind.emailUnconfirmed,
        statusCode: status,
        backendCode: error.code,
        cause: error,
      );
    }
    if (message.contains('already registered') ||
        message.contains('already been registered')) {
      return AuthSessionException(
        kind: AuthFailureKind.emailAlreadyRegistered,
        statusCode: status,
        backendCode: error.code,
        cause: error,
      );
    }
  }

  if (error is PostgrestException) {
    final code = error.code ?? '';
    if (code == '42501' || code == 'PGRST301') {
      return AuthSessionException(
        kind: AuthFailureKind.profileAccessDenied,
        backendCode: code,
        cause: error,
      );
    }
    if (_isProfileContractError(error)) {
      return _profileContractFailure(error, code: code);
    }
  }

  final message = error.toString().toLowerCase();
  if (message.contains('socketexception') ||
      message.contains('clientexception') ||
      message.contains('failed host lookup') ||
      message.contains('network request failed') ||
      message.contains('xmlhttprequest')) {
    return AuthSessionException(kind: AuthFailureKind.network, cause: error);
  }
  if (message.contains('pgrst200') ||
      message.contains('pgrst201') ||
      message.contains('pgrst202') ||
      message.contains('pgrst205') ||
      message.contains('schema cache') ||
      message.contains('get_my_session_profile')) {
    return _profileContractFailure(error);
  }
  if (message.contains('permission denied') || message.contains('42501')) {
    return AuthSessionException(
      kind: AuthFailureKind.profileAccessDenied,
      cause: error,
    );
  }
  return AuthSessionException(kind: AuthFailureKind.unknown, cause: error);
}

class BackendAccount {
  const BackendAccount({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
    required this.unit,
    required this.campusId,
    required this.verificationStatus,
    required this.accountStatus,
    required this.accountAccessType,
    required this.mustChangePassword,
    required this.createdAt,
    required this.lastSignInAt,
    required this.invitationSentAt,
    required this.emailConfirmedAt,
    required this.suspensionReason,
    required this.suspendedUntil,
    required this.isSelf,
    required this.activityMetricsAvailable,
    this.organizationSlotId,
    this.organizationSlotLabel,
    this.organizationUnitId,
    this.organizationUnitName,
    this.organizationUnitCode,
    this.organizationUnitType,
    this.organizationUnitBookingAudience,
    this.passwordIssuedAt,
    this.reservationCount = 0,
    this.lastReservationAt,
  });

  final String id;
  final String email;
  final String fullName;
  final String role;
  final String unit;
  final String campusId;
  final String verificationStatus;
  final String accountStatus;
  final String accountAccessType;
  final bool mustChangePassword;
  final DateTime? createdAt;
  final DateTime? lastSignInAt;
  final DateTime? invitationSentAt;
  final DateTime? emailConfirmedAt;
  final String? suspensionReason;
  final DateTime? suspendedUntil;
  final bool isSelf;
  final bool activityMetricsAvailable;
  final String? organizationSlotId;
  final String? organizationSlotLabel;
  final String? organizationUnitId;
  final String? organizationUnitName;
  final String? organizationUnitCode;
  final String? organizationUnitType;
  final String? organizationUnitBookingAudience;
  final DateTime? passwordIssuedAt;
  final int reservationCount;
  final DateTime? lastReservationAt;

  factory BackendAccount.fromJson(Map<String, dynamic> json) => BackendAccount(
    id: json['id'] as String,
    email: (json['email'] as String?) ?? '',
    fullName: (json['full_name'] as String?) ?? '',
    role: _accountRole(json['role']),
    unit: (json['unit'] as String?) ?? '',
    campusId: (json['campus_id'] as String?) ?? '',
    verificationStatus: (json['verification_status'] as String?) ?? 'none',
    accountStatus: (json['account_status'] as String?) ?? 'active',
    accountAccessType:
        (json['account_access_type'] as String?) ?? 'legacy_unassigned',
    mustChangePassword: (json['must_change_password'] as bool?) ?? false,
    createdAt: _date(json['created_at']),
    lastSignInAt: _date(json['last_sign_in_at']),
    invitationSentAt: _date(json['invitation_sent_at']),
    emailConfirmedAt: _date(json['email_confirmed_at']),
    suspensionReason: json['suspension_reason'] as String?,
    suspendedUntil: _date(json['suspended_until']),
    isSelf: (json['is_self'] as bool?) ?? false,
    activityMetricsAvailable:
        (json['activity_metrics_available'] as bool?) ?? false,
    organizationSlotId: json['organization_slot_id'] as String?,
    organizationSlotLabel: json['organization_slot_label'] as String?,
    organizationUnitId: json['organization_unit_id'] as String?,
    organizationUnitName: json['organization_unit_name'] as String?,
    organizationUnitCode: json['organization_unit_code'] as String?,
    organizationUnitType: json['organization_unit_type'] as String?,
    organizationUnitBookingAudience:
        json['organization_unit_booking_audience'] as String?,
    passwordIssuedAt: _date(json['password_issued_at']),
    reservationCount: (json['reservation_count'] as num?)?.toInt() ?? 0,
    lastReservationAt: _date(json['last_reservation_at']),
  );

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;
}

String _accountRole(Object? value) {
  return switch (value) {
    'user' => 'user',
    'internal_admin' => 'internal_admin',
    'external_admin' => 'external_admin',
    'student' || 'faculty' || 'staff' || 'guest' => 'user',
    _ => throw const FormatException(
      'Account response contains an invalid role.',
    ),
  };
}

class BackendCreatedAccount {
  const BackendCreatedAccount({
    required this.account,
    required this.temporaryPassword,
  });

  final BackendAccount account;
  final String temporaryPassword;
}

typedef BackendCreatedAdministrator = BackendCreatedAccount;

class BackendOrganizationUnit {
  const BackendOrganizationUnit({
    required this.id,
    this.parentId,
    required this.name,
    this.code,
    required this.unitType,
    required this.active,
    required this.requiresRepresentative,
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

  factory BackendOrganizationUnit.fromJson(Map<String, dynamic> json) =>
      BackendOrganizationUnit(
        id: json['id'] as String,
        parentId: json['parent_id'] as String?,
        name: (json['name'] as String?) ?? '',
        code: json['code'] as String?,
        unitType: (json['unit_type'] as String?) ?? 'department',
        active: (json['active'] as bool?) ?? true,
        requiresRepresentative:
            (json['requires_representative'] as bool?) ?? true,
        bookingAudience: json['booking_audience'] as String?,
      );
}

class BackendOrganizationAccountSlot {
  const BackendOrganizationAccountSlot({
    required this.id,
    required this.unitId,
    required this.label,
    required this.active,
    this.unit,
    this.assignedProfileId,
    this.assignedName,
    this.assignedEmail,
  });

  final String id;
  final String unitId;
  final String label;
  final bool active;
  final BackendOrganizationUnit? unit;
  final String? assignedProfileId;
  final String? assignedName;
  final String? assignedEmail;

  factory BackendOrganizationAccountSlot.fromJson(
    Map<String, dynamic> json, {
    BackendAccount? assignedAccount,
  }) {
    final unitJson = json['organizational_units'];
    return BackendOrganizationAccountSlot(
      id: json['id'] as String,
      unitId: json['unit_id'] as String,
      label: (json['label'] as String?) ?? 'Authorized representative',
      active: (json['active'] as bool?) ?? true,
      unit: unitJson is Map
          ? BackendOrganizationUnit.fromJson(
              Map<String, dynamic>.from(unitJson),
            )
          : null,
      assignedProfileId: assignedAccount?.id,
      assignedName: assignedAccount?.fullName,
      assignedEmail: assignedAccount?.email,
    );
  }
}

class BackendVerification {
  const BackendVerification({
    required this.id,
    required this.userId,
    required this.name,
    required this.email,
    required this.claimType,
    required this.campusId,
    required this.unit,
    required this.documentName,
    required this.documentPath,
    required this.status,
    required this.reason,
    required this.submittedAt,
    required this.decidedAt,
  });

  final String id;
  final String userId;
  final String name;
  final String email;
  final String claimType;
  final String campusId;
  final String unit;
  final String documentName;
  final String? documentPath;
  final String status;
  final String? reason;
  final DateTime submittedAt;
  final DateTime? decidedAt;

  bool get hasDocument => documentPath != null;

  factory BackendVerification.fromJson(Map<String, dynamic> json) {
    final profile = json['profiles'];
    final profileMap = profile is Map<String, dynamic>
        ? profile
        : <String, dynamic>{};
    return BackendVerification(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      name: (profileMap['full_name'] as String?) ?? '',
      email: (profileMap['email'] as String?) ?? '',
      claimType: json['claim_type'] as String,
      campusId: json['campus_id'] as String,
      unit: json['unit'] as String,
      documentName: json['document_name'] as String,
      documentPath: json['document_path'] as String?,
      status: json['status'] as String,
      reason: json['reason'] as String?,
      submittedAt: DateTime.parse(json['submitted_at'] as String),
      decidedAt: json['decided_at'] == null
          ? null
          : DateTime.parse(json['decided_at'] as String),
    );
  }
}

class ReservationUpload {
  const ReservationUpload({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

class ReservationDraft {
  const ReservationDraft({
    required this.facilityId,
    required this.purpose,
    required this.headcount,
    required this.startsAt,
    required this.endsAt,
    this.attachments = const [],
    this.paymentAmountCentavos = 0,
    this.requestedAmenities = const [],
    this.amenityIds = const [],
    this.termsVersionIds = const [],
    this.pricingFingerprint,
    this.discountClaimId,
    this.externalPermitDetails,
    this.permitItemQuantities = const {},
  });

  final String facilityId;
  final String purpose;
  final int headcount;
  final List<DateTime> startsAt;
  final List<DateTime> endsAt;
  final List<ReservationUpload> attachments;
  final int paymentAmountCentavos;
  final List<String> requestedAmenities;
  final List<String> amenityIds;
  final List<String> termsVersionIds;
  final String? pricingFingerprint;
  final String? discountClaimId;
  final ExternalPermitDetails? externalPermitDetails;
  final Map<String, int> permitItemQuantities;
}

class BackendPriceLine {
  const BackendPriceLine({
    required this.type,
    required this.label,
    required this.quantity,
    required this.unitAmountCentavos,
    required this.lineTotalCentavos,
    this.sourceId,
  });

  final String type;
  final String? sourceId;
  final String label;
  final double quantity;
  final int unitAmountCentavos;
  final int lineTotalCentavos;

  factory BackendPriceLine.fromJson(Map<String, dynamic> json) =>
      BackendPriceLine(
        type: '${json['line_type'] ?? ''}',
        sourceId: json['source_id'] as String?,
        label: '${json['label'] ?? ''}',
        quantity: (json['quantity'] as num?)?.toDouble() ?? 1,
        unitAmountCentavos:
            (json['unit_amount_centavos'] as num?)?.toInt() ?? 0,
        lineTotalCentavos: (json['line_total_centavos'] as num?)?.toInt() ?? 0,
      );
}

class BackendTermsVersion {
  const BackendTermsVersion({
    required this.id,
    required this.title,
    required this.version,
    required this.content,
    required this.contentHash,
  });

  final String id;
  final String title;
  final int version;
  final String content;
  final String contentHash;

  factory BackendTermsVersion.fromJson(Map<String, dynamic> json) =>
      BackendTermsVersion(
        id: '${json['id']}',
        title: '${json['title'] ?? ''}',
        version: (json['version'] as num?)?.toInt() ?? 1,
        content: '${json['content'] ?? ''}',
        contentHash: '${json['content_hash'] ?? ''}',
      );
}

class BackendReservationQuote {
  const BackendReservationQuote({
    required this.facilityId,
    required this.audience,
    required this.adminLane,
    required this.facilityAmountCentavos,
    required this.amenityAmountCentavos,
    required this.discountAmountCentavos,
    required this.totalAmountCentavos,
    required this.requiredDownPaymentCentavos,
    required this.pricingFingerprint,
    required this.lines,
    required this.terms,
    this.downPaymentPercent = 50,
    this.paymentExemption = 'none',
    this.discount,
  });

  final String facilityId;
  final String audience;
  final String adminLane;
  final int facilityAmountCentavos;
  final int amenityAmountCentavos;
  final int discountAmountCentavos;
  final int totalAmountCentavos;
  final int requiredDownPaymentCentavos;
  final String pricingFingerprint;
  final List<BackendPriceLine> lines;
  final List<BackendTermsVersion> terms;
  final int downPaymentPercent;
  final String paymentExemption;
  final LoyaltyQuoteDiscount? discount;

  bool get isPaymentExempt => paymentExemption != 'none';

  factory BackendReservationQuote.fromJson(Map<String, dynamic> json) {
    List<T> parse<T>(String key, T Function(Map<String, dynamic>) factory) =>
        ((json[key] as List?) ?? const [])
            .map((row) => factory(Map<String, dynamic>.from(row as Map)))
            .toList();
    final discountJson = json['discount'];
    final discount = discountJson is Map
        ? Map<String, dynamic>.from(discountJson)
        : null;
    return BackendReservationQuote(
      facilityId: '${json['facility_id']}',
      audience: '${json['audience'] ?? 'guest'}',
      adminLane: '${json['admin_lane'] ?? 'external'}',
      facilityAmountCentavos:
          (json['facility_amount_centavos'] as num?)?.toInt() ?? 0,
      amenityAmountCentavos:
          (json['amenity_amount_centavos'] as num?)?.toInt() ?? 0,
      discountAmountCentavos:
          (json['discount_amount_centavos'] as num?)?.toInt() ?? 0,
      totalAmountCentavos:
          (json['total_amount_centavos'] as num?)?.toInt() ?? 0,
      requiredDownPaymentCentavos:
          (json['required_down_payment_centavos'] as num?)?.toInt() ?? 0,
      pricingFingerprint: '${json['pricing_fingerprint'] ?? ''}',
      lines: parse('lines', BackendPriceLine.fromJson),
      terms: parse('terms', BackendTermsVersion.fromJson),
      downPaymentPercent: (json['down_payment_percent'] as num?)?.toInt() ?? 50,
      paymentExemption: '${json['payment_exemption'] ?? 'none'}',
      discount: discount != null
          ? LoyaltyQuoteDiscount(
              claimId: '${discount['claim_id']}',
              offerName: '${discount['offer_name'] ?? ''}',
              discountKind: DiscountKind.fromRaw(
                '${discount['discount_kind'] ?? ''}',
              ),
              fixedAmountCentavos: (discount['fixed_amount_centavos'] as num?)
                  ?.toInt(),
              percentage: (discount['percentage'] as num?)?.toDouble(),
              discountAmountCentavos:
                  (discount['discount_amount_centavos'] as num?)?.toInt() ?? 0,
              expiryDate: DateTime.tryParse('${discount['expiry_date'] ?? ''}'),
              facilityId: discount['facility_id'] as String?,
            )
          : null,
    );
  }
}

class PaymentSubmissionDraft {
  const PaymentSubmissionDraft({
    required this.requestId,
    required this.purpose,
    required this.amountCentavos,
    required this.referenceNumber,
    required this.proof,
  });

  final String requestId;
  final PaymentPurpose purpose;
  final int amountCentavos;
  final String referenceNumber;
  final ReservationUpload proof;
}

class FacilityConfigurationDraft {
  const FacilityConfigurationDraft({
    required this.facilityId,
    required this.rates,
    required this.amenities,
    required this.accountName,
    required this.accountNumber,
    required this.instructions,
    required this.depositWindowMinutes,
    required this.balanceDueLeadMinutes,
    required this.correctionWindowMinutes,
    this.downPaymentPercent = 50,
    this.internalPermitRowCode,
    this.externalPermitRowCode,
  });

  final String facilityId;
  final Map<String, int> rates;
  final List<FacilityAmenity> amenities;
  final String accountName;
  final String accountNumber;
  final String instructions;
  final int depositWindowMinutes;
  final int balanceDueLeadMinutes;
  final int correctionWindowMinutes;
  final int downPaymentPercent;
  final String? internalPermitRowCode;
  final String? externalPermitRowCode;
}

class BackendReservationOccurrence {
  const BackendReservationOccurrence({
    required this.id,
    required this.startsAt,
    required this.endsAt,
    required this.bookingState,
    required this.lifecycleStage,
    this.proposedStartsAt,
    this.proposedEndsAt,
    this.exceptionReason,
    this.attendanceMarkedAt,
    this.attendanceMarkedBy,
    this.attendanceReason,
    this.cancelledAt,
    this.cancelledBy,
    this.cancellationReason,
  });

  final String id;
  final DateTime startsAt;
  final DateTime endsAt;
  final String bookingState;
  final String lifecycleStage;
  final DateTime? proposedStartsAt;
  final DateTime? proposedEndsAt;
  final String? exceptionReason;
  final DateTime? attendanceMarkedAt;
  final String? attendanceMarkedBy;
  final String? attendanceReason;
  final DateTime? cancelledAt;
  final String? cancelledBy;
  final String? cancellationReason;

  factory BackendReservationOccurrence.fromJson(Map<String, dynamic> json) =>
      BackendReservationOccurrence(
        id: json['id'] as String,
        startsAt: DateTime.parse(json['starts_at'] as String),
        endsAt: DateTime.parse(json['ends_at'] as String),
        bookingState: '${json['booking_state'] ?? 'requested'}',
        lifecycleStage: '${json['lifecycle_stage'] ?? 'booked'}',
        proposedStartsAt: _date(json['proposed_starts_at']),
        proposedEndsAt: _date(json['proposed_ends_at']),
        exceptionReason: json['exception_reason'] as String?,
        attendanceMarkedAt: _date(json['attendance_marked_at']),
        attendanceMarkedBy: json['attendance_marked_by'] as String?,
        attendanceReason: json['attendance_reason'] as String?,
        cancelledAt: _date(json['cancelled_at']),
        cancelledBy: json['cancelled_by'] as String?,
        cancellationReason: json['cancellation_reason'] as String?,
      );
}

class BackendReservationAttachment {
  const BackendReservationAttachment({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.byteSize,
    required this.storagePath,
  });

  final String id;
  final String fileName;
  final String mimeType;
  final int byteSize;
  final String storagePath;

  factory BackendReservationAttachment.fromJson(Map<String, dynamic> json) =>
      BackendReservationAttachment(
        id: json['id'] as String,
        fileName: '${json['file_name'] ?? ''}',
        mimeType: '${json['mime_type'] ?? ''}',
        byteSize: (json['byte_size'] as num?)?.toInt() ?? 0,
        storagePath: '${json['storage_path'] ?? ''}',
      );
}

class BackendReservationUseAssessment {
  const BackendReservationUseAssessment({
    required this.id,
    required this.requestId,
    required this.occurrenceId,
    required this.facilityId,
    required this.requesterId,
    required this.adminId,
    required this.cleanlinessRating,
    required this.equipmentConditionRating,
    required this.leftUnclean,
    required this.equipmentDamaged,
    required this.comment,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.files = const [],
  });

  final String id;
  final String requestId;
  final String occurrenceId;
  final String facilityId;
  final String requesterId;
  final String adminId;
  final int cleanlinessRating;
  final int equipmentConditionRating;
  final bool leftUnclean;
  final bool equipmentDamaged;
  final String comment;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<BackendReservationUseAssessmentFile> files;

  factory BackendReservationUseAssessment.fromJson(Map<String, dynamic> json) =>
      BackendReservationUseAssessment(
        id: '${json['id']}',
        requestId: '${json['request_id']}',
        occurrenceId: '${json['occurrence_id']}',
        facilityId: '${json['facility_id']}',
        requesterId: '${json['requester_id']}',
        adminId: '${json['admin_id']}',
        cleanlinessRating: (json['cleanliness_rating'] as num?)?.toInt() ?? 1,
        equipmentConditionRating:
            (json['equipment_condition_rating'] as num?)?.toInt() ?? 1,
        leftUnclean: json['left_unclean'] as bool? ?? false,
        equipmentDamaged: json['equipment_damaged'] as bool? ?? false,
        comment: '${json['comment'] ?? ''}',
        revision: (json['revision'] as num?)?.toInt() ?? 1,
        createdAt: DateTime.parse('${json['created_at']}'),
        updatedAt: DateTime.parse('${json['updated_at']}'),
        files: [
          for (final raw
              in (json['reservation_use_assessment_files'] as List? ??
                  const []))
            BackendReservationUseAssessmentFile.fromJson(
              Map<String, dynamic>.from(raw as Map),
            ),
        ],
      );
}

class BackendReservationUseAssessmentFile {
  const BackendReservationUseAssessmentFile({
    required this.id,
    required this.assessmentId,
    required this.storagePath,
    required this.fileName,
    required this.mimeType,
    required this.byteSize,
  });

  final String id;
  final String assessmentId;
  final String storagePath;
  final String fileName;
  final String mimeType;
  final int byteSize;

  factory BackendReservationUseAssessmentFile.fromJson(
    Map<String, dynamic> json,
  ) => BackendReservationUseAssessmentFile(
    id: '${json['id']}',
    assessmentId: '${json['assessment_id']}',
    storagePath: '${json['storage_path'] ?? ''}',
    fileName: '${json['file_name'] ?? ''}',
    mimeType: '${json['mime_type'] ?? ''}',
    byteSize: (json['byte_size'] as num?)?.toInt() ?? 0,
  );
}

class BackendReservationEvent {
  const BackendReservationEvent({
    required this.id,
    required this.actorName,
    required this.actorRole,
    required this.action,
    required this.createdAt,
    required this.material,
    this.reason,
    this.details = const {},
  });

  final String id;
  final String actorName;
  final String actorRole;
  final String action;
  final DateTime createdAt;
  final bool material;
  final String? reason;
  final Map<String, dynamic> details;

  factory BackendReservationEvent.fromJson(Map<String, dynamic> json) =>
      BackendReservationEvent(
        id: json['id'] as String,
        actorName: '${json['actor_name'] ?? 'the system'}',
        actorRole: '${json['actor_role'] ?? 'system'}',
        action: '${json['action'] ?? ''}',
        createdAt: DateTime.parse(json['created_at'] as String),
        material: json['material'] as bool? ?? true,
        reason: json['reason'] as String?,
        details: Map<String, dynamic>.from(
          (json['details'] as Map?) ?? const {},
        ),
      );
}

class BackendBusyWindow {
  const BackendBusyWindow({
    required this.facilityId,
    required this.startsAt,
    required this.endsAt,
  });

  final String facilityId;
  final DateTime startsAt;
  final DateTime endsAt;

  factory BackendBusyWindow.fromJson(Map<String, dynamic> json) =>
      BackendBusyWindow(
        facilityId: '${json['facility_id']}',
        startsAt: DateTime.parse('${json['starts_at']}').toUtc(),
        endsAt: DateTime.parse('${json['ends_at']}').toUtc(),
      );
}

class BackendPublicReservationSlot {
  const BackendPublicReservationSlot({
    required this.facilityId,
    required this.startsAt,
    required this.endsAt,
  });

  final String facilityId;
  final DateTime startsAt;
  final DateTime endsAt;

  factory BackendPublicReservationSlot.fromJson(Map<String, dynamic> json) =>
      BackendPublicReservationSlot(
        facilityId: '${json['facility_id']}',
        startsAt: DateTime.parse('${json['starts_at']}').toUtc(),
        endsAt: DateTime.parse('${json['ends_at']}').toUtc(),
      );
}

class BackendReservation {
  const BackendReservation({
    required this.id,
    required this.requesterId,
    required this.facilityId,
    required this.requesterName,
    required this.requesterRole,
    required this.requesterUnit,
    required this.facilityName,
    required this.facilityBuilding,
    required this.facilityRoom,
    required this.facilityCapacity,
    required this.purpose,
    required this.headcount,
    required this.status,
    required this.heldForVerification,
    required this.recurrence,
    required this.paymentAmountCentavos,
    required this.paymentStatus,
    required this.version,
    required this.createdAt,
    required this.occurrences,
    required this.attachments,
    required this.events,
    this.amenities = const [],
    this.decisionReason,
    this.decidedByName,
    this.decidedAt,
    this.adminLane = 'external',
    this.reservationStatus = 'pending_approval',
    this.pricingAudience = 'guest',
    this.facilityAmountCentavos = 0,
    this.amenityAmountCentavos = 0,
    this.discountAmountCentavos = 0,
    this.totalAmountCentavos = 0,
    this.requiredDownPaymentCentavos = 0,
    this.downPaymentPercent = 50,
    this.paymentExemption = 'none',
    this.pricingFingerprint = '',
    this.paymentDueAt,
    this.balanceDueAt,
    this.legacyFinancialState = false,
    this.payments = const [],
    this.paymentMethod,
    this.priceLines = const [],
    this.acceptedTerms = const [],
    this.feedback,
    this.permit,
    this.signatureRequestId,
    this.signatureRequestStatus,
    this.useAssessments = const [],
    this.requesterCategory = 'external_renter',
    this.externalCompanyOrganization,
    this.externalCompleteAddress,
    this.externalContactNumbers = const [],
    this.externalAdmissionFeeCentavos,
  });

  final String id;
  final String requesterId;
  final String facilityId;
  final String requesterName;
  final String requesterRole;
  final String requesterUnit;
  final String facilityName;
  final String facilityBuilding;
  final String facilityRoom;
  final int facilityCapacity;
  final String purpose;
  final int headcount;
  final String status;
  final bool heldForVerification;
  final String recurrence;
  final String? decisionReason;
  final String? decidedByName;
  final DateTime? decidedAt;
  final int paymentAmountCentavos;
  final String paymentStatus;
  final int version;
  final DateTime createdAt;
  final List<BackendReservationOccurrence> occurrences;
  final List<BackendReservationAttachment> attachments;
  final List<BackendReservationEvent> events;
  final List<String> amenities;
  final String adminLane;
  final String reservationStatus;
  final String pricingAudience;
  final int facilityAmountCentavos;
  final int amenityAmountCentavos;
  final int discountAmountCentavos;
  final int totalAmountCentavos;
  final int requiredDownPaymentCentavos;
  final int downPaymentPercent;
  final String paymentExemption;
  final String pricingFingerprint;
  final DateTime? paymentDueAt;
  final DateTime? balanceDueAt;
  final bool legacyFinancialState;
  final List<PaymentTransaction> payments;
  final FacilityPaymentMethod? paymentMethod;
  final List<BackendPriceLine> priceLines;
  final List<AcceptedTerms> acceptedTerms;
  final BackendFeedback? feedback;
  final ReservationPermit? permit;
  final String? signatureRequestId;
  final String? signatureRequestStatus;
  final List<BackendReservationUseAssessment> useAssessments;
  final String requesterCategory;
  final String? externalCompanyOrganization;
  final String? externalCompleteAddress;
  final List<String> externalContactNumbers;
  final int? externalAdmissionFeeCentavos;

  factory BackendReservation.fromJson(Map<String, dynamic> json) {
    List<T> rows<T>(String key, T Function(Map<String, dynamic>) parse) =>
        ((json[key] as List?) ?? const [])
            .map((row) => parse(Map<String, dynamic>.from(row as Map)))
            .toList();
    final occurrences = rows(
      'reservation_occurrences',
      BackendReservationOccurrence.fromJson,
    )..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    final events = rows('reservation_events', BackendReservationEvent.fromJson)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final signature = _latestSignatureRequest(
      json['reservation_signature_requests'],
    );
    return BackendReservation(
      id: json['id'] as String,
      requesterId: json['requester_id'] as String,
      facilityId: json['facility_id'] as String,
      requesterName: '${json['requester_name'] ?? ''}',
      requesterRole: '${json['requester_role'] ?? ''}',
      requesterUnit: '${json['requester_unit'] ?? ''}',
      facilityName: '${json['facility_name'] ?? ''}',
      facilityBuilding: '${json['facility_building'] ?? ''}',
      facilityRoom: '${json['facility_room'] ?? ''}',
      facilityCapacity: (json['facility_capacity'] as num?)?.toInt() ?? 0,
      purpose: '${json['purpose'] ?? ''}',
      headcount: (json['headcount'] as num?)?.toInt() ?? 0,
      status: '${json['status'] ?? 'pending'}',
      heldForVerification: json['held_for_verification'] as bool? ?? false,
      recurrence: '${json['recurrence'] ?? 'none'}',
      decisionReason: json['decision_reason'] as String?,
      decidedByName: json['decided_by_name'] as String?,
      decidedAt: _date(json['decided_at']),
      paymentAmountCentavos:
          (json['payment_amount_centavos'] as num?)?.toInt() ?? 0,
      paymentStatus: '${json['payment_status'] ?? 'not_required'}',
      version: (json['version'] as num?)?.toInt() ?? 1,
      createdAt: DateTime.parse(json['created_at'] as String),
      occurrences: occurrences,
      attachments: rows(
        'reservation_attachments',
        BackendReservationAttachment.fromJson,
      ),
      events: events,
      amenities: [
        for (final value in (json['amenities'] as List? ?? const [])) '$value',
      ],
      adminLane: '${json['admin_lane'] ?? 'external'}',
      reservationStatus:
          '${json['reservation_status'] ?? _legacyLifecycle('${json['status']}')}',
      pricingAudience: '${json['pricing_audience'] ?? 'guest'}',
      facilityAmountCentavos:
          (json['facility_amount_centavos'] as num?)?.toInt() ?? 0,
      amenityAmountCentavos:
          (json['amenity_amount_centavos'] as num?)?.toInt() ?? 0,
      discountAmountCentavos:
          (json['discount_amount_centavos'] as num?)?.toInt() ?? 0,
      totalAmountCentavos:
          (json['total_amount_centavos'] as num?)?.toInt() ??
          (json['payment_amount_centavos'] as num?)?.toInt() ??
          0,
      requiredDownPaymentCentavos:
          (json['required_down_payment_centavos'] as num?)?.toInt() ?? 0,
      downPaymentPercent: (json['down_payment_percent'] as num?)?.toInt() ?? 50,
      paymentExemption: '${json['payment_exemption'] ?? 'none'}',
      pricingFingerprint: '${json['pricing_fingerprint'] ?? ''}',
      paymentDueAt: _date(json['payment_due_at']),
      balanceDueAt: _date(json['balance_due_at']),
      legacyFinancialState: json['legacy_financial_state'] as bool? ?? false,
      payments: [
        for (final raw in (json['payment_transactions'] as List? ?? const []))
          _paymentTransaction(Map<String, dynamic>.from(raw as Map)),
      ],
      paymentMethod: json['payment_method'] is Map
          ? _facilityPaymentMethod(
              Map<String, dynamic>.from(json['payment_method'] as Map),
            )
          : null,
      priceLines: rows('reservation_price_lines', BackendPriceLine.fromJson),
      acceptedTerms: [
        for (final raw
            in (json['reservation_terms_acceptances'] as List? ?? const []))
          if ((raw as Map)['terms_versions'] is Map)
            AcceptedTerms(
              id: '${(raw['terms_versions'] as Map)['id']}',
              title: '${(raw['terms_versions'] as Map)['title'] ?? ''}',
              version:
                  ((raw['terms_versions'] as Map)['version'] as num?)
                      ?.toInt() ??
                  1,
              content: '${(raw['terms_versions'] as Map)['content'] ?? ''}',
              contentHash: '${raw['content_hash'] ?? ''}',
              acceptedAt: DateTime.parse('${raw['accepted_at']}'),
            ),
      ],
      feedback: _embeddedOne(json['reservation_feedback']) == null
          ? null
          : BackendFeedback.fromJson(
              _embeddedOne(json['reservation_feedback'])!,
            ),
      permit: _activePermit(json['reservation_permits']),
      signatureRequestId: signature?.id,
      signatureRequestStatus: signature?.status,
      useAssessments: [
        for (final raw
            in (json['reservation_use_assessments'] as List? ?? const []))
          BackendReservationUseAssessment.fromJson(
            Map<String, dynamic>.from(raw as Map),
          ),
      ],
      requesterCategory: '${json['requester_category'] ?? 'external_renter'}',
      externalCompanyOrganization:
          json['external_company_organization'] as String?,
      externalCompleteAddress: json['external_complete_address'] as String?,
      externalContactNumbers: [
        for (final value
            in json['external_contact_numbers'] as List? ?? const [])
          '$value',
      ],
      externalAdmissionFeeCentavos:
          (json['external_admission_fee_centavos'] as num?)?.toInt(),
    );
  }
}

ReservationPermit? _activePermit(dynamic raw) {
  final rows = (raw as List? ?? const [])
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
  final active = rows.where((row) => row['status'] == 'active').toList();
  if (active.isEmpty) return null;
  return ReservationPermit.fromJson(active.first);
}

({String id, String status})? _latestSignatureRequest(dynamic raw) {
  final rows =
      (raw as List? ?? const [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList()
        ..sort(
          (a, b) => '${b['requested_at']}'.compareTo('${a['requested_at']}'),
        );
  if (rows.isEmpty) return null;
  final row = rows.first;
  return (id: '${row['id']}', status: '${row['status']}');
}

String _legacyLifecycle(String status) => switch (status) {
  'approved' => 'confirmed',
  'changes_requested' => 'changes_requested',
  'declined' => 'declined',
  'cancelled' => 'cancelled',
  'expired' => 'expired',
  _ => 'pending_approval',
};

PaymentTransaction _paymentTransaction(Map<String, dynamic> json) =>
    PaymentTransaction(
      id: '${json['id']}',
      requestId: '${json['request_id']}',
      payerId: '${json['payer_id']}',
      purpose: PaymentPurpose.fromRaw('${json['purpose']}'),
      amountCentavos: (json['amount_centavos'] as num?)?.toInt() ?? 0,
      referenceNumber: '${json['reference_number'] ?? ''}',
      proofPath: '${json['proof_path'] ?? ''}',
      status: PaymentDecisionStatus.fromRaw('${json['status']}'),
      submittedAt: DateTime.parse('${json['submitted_at']}'),
      verifiedBy: json['verified_by'] as String?,
      verifiedAt: _date(json['verified_at']),
      rejectionReason: json['rejection_reason'] as String?,
      correctionDueAt: _date(json['correction_due_at']),
      correctionCount: (json['correction_count'] as num?)?.toInt() ?? 0,
      lastCorrectedAt: _date(json['last_corrected_at']),
    );

class ReservationActionCommand {
  const ReservationActionCommand({
    required this.requestId,
    required this.action,
    required this.expectedVersion,
    this.reason,
    this.payload = const {},
    this.idempotencyKey,
  });

  final String requestId;
  final String action;
  final int expectedVersion;
  final String? reason;
  final Map<String, dynamic> payload;
  final String? idempotencyKey;
}

class ReservationActionResult {
  const ReservationActionResult({
    this.actionId,
    this.actionIds = const [],
    this.undoUntil,
  });
  final String? actionId;
  final List<String> actionIds;
  final DateTime? undoUntil;
}

class BackendNotification {
  const BackendNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    this.requestId,
    this.anomalyId,
    this.readAt,
  });

  final String id;
  final String kind;
  final String title;
  final String body;
  final String? requestId;
  final String? anomalyId;
  final DateTime createdAt;
  final DateTime? readAt;

  bool get unread => readAt == null;

  factory BackendNotification.fromJson(Map<String, dynamic> json) =>
      BackendNotification(
        id: json['id'] as String,
        kind: '${json['kind'] ?? ''}',
        title: '${json['title'] ?? ''}',
        body: '${json['body'] ?? ''}',
        requestId: json['request_id'] as String?,
        anomalyId: json['anomaly_id'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        readAt: _date(json['read_at']),
      );
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;

double? _decimal(Object? value) => switch (value) {
  num n => n.toDouble(),
  String s => double.tryParse(s),
  _ => null,
};

int _int(Object? value) => switch (value) {
  num n => n.toInt(),
  String s => int.tryParse(s) ?? 0,
  _ => 0,
};

Map<String, dynamic>? _embeddedOne(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is List && value.isNotEmpty) {
    return Map<String, dynamic>.from(value.first as Map);
  }
  return null;
}

class AuditQuery {
  const AuditQuery({
    this.search = '',
    this.actor,
    this.entityType,
    this.materialOnly = false,
    this.from,
    this.to,
    this.beforeCreatedAt,
    this.beforeId,
    this.limit = 50,
  });
  final String search;
  final String? actor;
  final String? entityType;
  final bool materialOnly;
  final DateTime? from;
  final DateTime? to;
  final DateTime? beforeCreatedAt;
  final String? beforeId;
  final int limit;
  AuditQuery copyWith({
    String? search,
    String? actor,
    bool clearActor = false,
    String? entityType,
    bool clearEntityType = false,
    bool? materialOnly,
    DateTime? from,
    bool clearFrom = false,
    DateTime? to,
    bool clearTo = false,
    DateTime? beforeCreatedAt,
    String? beforeId,
    bool resetPage = false,
  }) => AuditQuery(
    search: search ?? this.search,
    actor: clearActor ? null : actor ?? this.actor,
    entityType: clearEntityType ? null : entityType ?? this.entityType,
    materialOnly: materialOnly ?? this.materialOnly,
    from: clearFrom ? null : from ?? this.from,
    to: clearTo ? null : to ?? this.to,
    beforeCreatedAt: resetPage ? null : beforeCreatedAt ?? this.beforeCreatedAt,
    beforeId: resetPage ? null : beforeId ?? this.beforeId,
    limit: limit,
  );
  Map<String, dynamic> get filters => {
    'search': search,
    'actor': actor,
    'entity_type': entityType,
    'material_only': materialOnly,
    'from': from?.toUtc().toIso8601String(),
    'to': to?.toUtc().toIso8601String(),
  };
}

class AuditPage {
  const AuditPage({
    required this.entries,
    required this.total,
    required this.actors,
  });
  final List<AuditEntry> entries;
  final int total;
  final List<String> actors;
  factory AuditPage.fromJson(Map<String, dynamic> json) => AuditPage(
    entries: ((json['rows'] as List?) ?? const [])
        .map(
          (row) => AuditEntry.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList(),
    total: (json['total'] as num?)?.toInt() ?? 0,
    actors: ((json['actors'] as List?) ?? const [])
        .map((value) => '$value')
        .toList(),
  );
}

class BackendFeedbackTopicSentiment {
  const BackendFeedbackTopicSentiment({
    required this.topic,
    required this.sentiment,
  });

  final FeedbackTopic topic;
  final SentimentLabel sentiment;

  factory BackendFeedbackTopicSentiment.fromJson(Map<String, dynamic> json) {
    final topic = FeedbackTopic.fromValue('${json['topic'] ?? ''}');
    final sentiment = SentimentLabel.fromValue('${json['sentiment'] ?? ''}');
    if (topic == null ||
        sentiment == null ||
        sentiment == SentimentLabel.unknown) {
      throw const FormatException('Feedback topic sentiment is invalid.');
    }
    return BackendFeedbackTopicSentiment(topic: topic, sentiment: sentiment);
  }

  FeedbackTopicSentiment toModel() =>
      FeedbackTopicSentiment(topic: topic, sentiment: sentiment);
}

class BackendFeedbackSentimentAnalysis {
  const BackendFeedbackSentimentAnalysis({
    required this.id,
    required this.feedbackId,
    required this.analysisVersion,
    required this.status,
    this.sentiment,
    this.confidence,
    this.topics = const [],
    this.provider,
    this.model,
    this.attemptCount = 0,
    this.lastErrorCode,
    this.processingStartedAt,
    this.analyzedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String feedbackId;
  final int analysisVersion;
  final SentimentAnalysisStatus status;
  final SentimentLabel? sentiment;
  final double? confidence;
  final List<BackendFeedbackTopicSentiment> topics;
  final String? provider;
  final String? model;
  final int attemptCount;
  final String? lastErrorCode;
  final DateTime? processingStartedAt;
  final DateTime? analyzedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory BackendFeedbackSentimentAnalysis.fromJson(Map<String, dynamic> json) {
    final status = SentimentAnalysisStatus.fromValue('${json['status'] ?? ''}');
    final sentiment = SentimentLabel.fromValue(json['sentiment'] as String?);
    return BackendFeedbackSentimentAnalysis(
      id: '${json['id']}',
      feedbackId: '${json['feedback_id']}',
      analysisVersion: _int(json['analysis_version']),
      status: status,
      sentiment: sentiment,
      confidence: _decimal(json['confidence']),
      topics: ((json['topic_sentiments'] as List?) ?? const [])
          .map(
            (row) => BackendFeedbackTopicSentiment.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
          )
          .toList(),
      provider: json['provider'] as String?,
      model: json['model'] as String?,
      attemptCount: _int(json['attempt_count']),
      lastErrorCode: json['last_error_code'] as String?,
      processingStartedAt: _date(json['processing_started_at']),
      analyzedAt: _date(json['analyzed_at']),
      createdAt: DateTime.parse('${json['created_at']}'),
      updatedAt: DateTime.parse('${json['updated_at']}'),
    );
  }

  static BackendFeedbackSentimentAnalysis? maybeFromJson(Object? value) {
    if (value is! Map) return null;
    return BackendFeedbackSentimentAnalysis.fromJson(
      Map<String, dynamic>.from(value),
    );
  }

  FeedbackSentimentAnalysis toModel() => FeedbackSentimentAnalysis(
    id: id,
    feedbackId: feedbackId,
    analysisVersion: analysisVersion,
    status: status,
    sentiment: sentiment,
    confidence: confidence,
    topics: [for (final topic in topics) topic.toModel()],
    provider: provider,
    model: model,
    attemptCount: attemptCount,
    lastErrorCode: lastErrorCode,
    processingStartedAt: processingStartedAt,
    analyzedAt: analyzedAt,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

class BackendFeedback {
  const BackendFeedback({
    required this.id,
    required this.reservationId,
    required this.facilityId,
    required this.userId,
    required this.rating,
    this.cleanlinessRating,
    this.conditionRating,
    this.equipmentRating,
    this.comment = '',
    required this.createdAt,
    required this.updatedAt,
    this.facilityName = '',
    this.requesterName = '',
    this.reservationStartsAt,
    this.pricingAudience = '',
    this.sentimentAnalysis,
  });

  final String id;
  final String reservationId;
  final String facilityId;
  final String userId;
  final int rating;
  final int? cleanlinessRating;
  final int? conditionRating;
  final int? equipmentRating;
  final String comment;
  final DateTime createdAt;
  final DateTime updatedAt;

  final String facilityName;
  final String requesterName;
  final DateTime? reservationStartsAt;
  final String pricingAudience;
  final BackendFeedbackSentimentAnalysis? sentimentAnalysis;

  factory BackendFeedback.fromJson(Map<String, dynamic> json) =>
      BackendFeedback(
        id: '${json['id']}',
        reservationId: '${json['reservation_id']}',
        facilityId: '${json['facility_id']}',
        userId: '${json['user_id']}',
        rating: (json['rating'] as num).toInt(),
        cleanlinessRating: (json['cleanliness_rating'] as num?)?.toInt(),
        conditionRating: (json['condition_rating'] as num?)?.toInt(),
        equipmentRating: (json['equipment_rating'] as num?)?.toInt(),
        comment: '${json['comment'] ?? ''}',
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
        facilityName: '${json['facility_name'] ?? ''}',
        requesterName: '${json['requester_name'] ?? ''}',
        reservationStartsAt: _date(json['reservation_starts_at']),
        pricingAudience: '${json['pricing_audience'] ?? ''}',
        sentimentAnalysis: BackendFeedbackSentimentAnalysis.maybeFromJson(
          json['sentiment_analysis'],
        ),
      );

  ReservationFeedback toModel() => ReservationFeedback(
    id: id,
    reservationId: reservationId,
    facilityId: facilityId,
    facilityName: facilityName,
    userId: userId,
    rating: rating,
    cleanlinessRating: cleanlinessRating,
    conditionRating: conditionRating,
    equipmentRating: equipmentRating,
    comment: comment,
    createdAt: createdAt,
    updatedAt: updatedAt,
    sentimentAnalysis: sentimentAnalysis?.toModel(),
  );
}

class BackendFeedbackPage {
  const BackendFeedbackPage({required this.entries, required this.total});

  final List<BackendFeedback> entries;
  final int total;

  factory BackendFeedbackPage.fromJson(Map<String, dynamic> json) =>
      BackendFeedbackPage(
        entries: ((json['rows'] as List?) ?? const [])
            .map(
              (row) => BackendFeedback.fromJson(
                Map<String, dynamic>.from(row as Map),
              ),
            )
            .toList(),
        total: (json['total'] as num?)?.toInt() ?? 0,
      );
}

class BackendFacilityRating {
  const BackendFacilityRating({
    required this.facilityId,
    required this.facilityName,
    required this.average,
    required this.total,
  });

  final String facilityId;
  final String facilityName;
  final double average;
  final int total;

  factory BackendFacilityRating.fromJson(Map<String, dynamic> json) =>
      BackendFacilityRating(
        facilityId: '${json['facility_id']}',
        facilityName: '${json['facility_name'] ?? ''}',
        average: _decimal(json['average']) ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
      );

  FacilityRatingStat toModel() => FacilityRatingStat(
    facilityId: facilityId,
    facilityName: facilityName,
    average: average,
    total: total,
  );
}

class BackendFeedbackSummary {
  const BackendFeedbackSummary({
    this.average,
    this.total = 0,
    this.fiveStar = 0,
    this.lowRated = 0,
    this.highest = const [],
    this.lowest = const [],
  });

  final double? average;
  final int total;
  final int fiveStar;
  final int lowRated;
  final List<BackendFacilityRating> highest;
  final List<BackendFacilityRating> lowest;

  factory BackendFeedbackSummary.fromJson(Map<String, dynamic> json) =>
      BackendFeedbackSummary(
        average: _decimal(json['average']),
        total: (json['total'] as num?)?.toInt() ?? 0,
        fiveStar: (json['five_star'] as num?)?.toInt() ?? 0,
        lowRated: (json['low_rated'] as num?)?.toInt() ?? 0,
        highest: ((json['highest'] as List?) ?? const [])
            .map(
              (row) => BackendFacilityRating.fromJson(
                Map<String, dynamic>.from(row as Map),
              ),
            )
            .toList(),
        lowest: ((json['lowest'] as List?) ?? const [])
            .map(
              (row) => BackendFacilityRating.fromJson(
                Map<String, dynamic>.from(row as Map),
              ),
            )
            .toList(),
      );

  FeedbackSummary toModel() => FeedbackSummary(
    average: average,
    total: total,
    fiveStar: fiveStar,
    lowRated: lowRated,
    highest: highest.map((row) => row.toModel()).toList(),
    lowest: lowest.map((row) => row.toModel()).toList(),
  );
}

class BackendFeedbackSentimentTrendPoint {
  const BackendFeedbackSentimentTrendPoint({
    required this.bucketStart,
    this.positive = 0,
    this.neutral = 0,
    this.negative = 0,
    this.mixed = 0,
    this.classified = 0,
    this.averageRating,
  });

  final DateTime bucketStart;
  final int positive;
  final int neutral;
  final int negative;
  final int mixed;
  final int classified;
  final double? averageRating;

  factory BackendFeedbackSentimentTrendPoint.fromJson(
    Map<String, dynamic> json,
  ) => BackendFeedbackSentimentTrendPoint(
    bucketStart: DateTime.parse('${json['bucket_start']}'),
    positive: _int(json['positive']),
    neutral: _int(json['neutral']),
    negative: _int(json['negative']),
    mixed: _int(json['mixed']),
    classified: _int(json['classified']),
    averageRating: _decimal(json['average_rating']),
  );

  FeedbackSentimentTrendPoint toModel() => FeedbackSentimentTrendPoint(
    bucketStart: bucketStart,
    positive: positive,
    neutral: neutral,
    negative: negative,
    mixed: mixed,
    classified: classified,
    averageRating: averageRating,
  );
}

class BackendFacilitySentimentInsight {
  const BackendFacilitySentimentInsight({
    required this.facilityId,
    required this.facilityName,
    this.classified = 0,
    this.positive = 0,
    this.neutral = 0,
    this.negative = 0,
    this.mixed = 0,
    this.needsReview = 0,
    this.averageRating,
  });

  final String facilityId;
  final String facilityName;
  final int classified;
  final int positive;
  final int neutral;
  final int negative;
  final int mixed;
  final int needsReview;
  final double? averageRating;

  factory BackendFacilitySentimentInsight.fromJson(Map<String, dynamic> json) =>
      BackendFacilitySentimentInsight(
        facilityId: '${json['facility_id']}',
        facilityName: '${json['facility_name'] ?? ''}',
        classified: _int(json['classified']),
        positive: _int(json['positive']),
        neutral: _int(json['neutral']),
        negative: _int(json['negative']),
        mixed: _int(json['mixed']),
        needsReview: _int(json['needs_review']),
        averageRating: _decimal(json['average_rating']),
      );

  FacilitySentimentInsight toModel() => FacilitySentimentInsight(
    facilityId: facilityId,
    facilityName: facilityName,
    classified: classified,
    positive: positive,
    neutral: neutral,
    negative: negative,
    mixed: mixed,
    needsReview: needsReview,
    averageRating: averageRating,
  );
}

class BackendComplaintTopicInsight {
  const BackendComplaintTopicInsight({
    required this.topic,
    this.count = 0,
    this.facilityCount = 0,
  });

  final FeedbackTopic topic;
  final int count;
  final int facilityCount;

  factory BackendComplaintTopicInsight.fromJson(Map<String, dynamic> json) {
    final topic = FeedbackTopic.fromValue('${json['topic'] ?? ''}');
    if (topic == null) {
      throw const FormatException('Feedback complaint topic is invalid.');
    }
    return BackendComplaintTopicInsight(
      topic: topic,
      count: _int(json['count']),
      facilityCount: _int(json['facility_count']),
    );
  }

  ComplaintTopicInsight toModel() => ComplaintTopicInsight(
    topic: topic,
    count: count,
    facilityCount: facilityCount,
  );
}

class BackendFeedbackSentimentAnalytics {
  const BackendFeedbackSentimentAnalytics({
    this.totalFeedback = 0,
    this.writtenFeedback = 0,
    this.classifiedFeedback = 0,
    this.pending = 0,
    this.processing = 0,
    this.failed = 0,
    this.skipped = 0,
    this.notAnalyzed = 0,
    this.averageRating,
    this.positive = 0,
    this.neutral = 0,
    this.negative = 0,
    this.mixed = 0,
    this.unknown = 0,
    this.needsReview = 0,
    this.ratingMismatch = 0,
    this.trendBucket = 'day',
    this.trend = const [],
    this.facilities = const [],
    this.complaints = const [],
  });

  final int totalFeedback;
  final int writtenFeedback;
  final int classifiedFeedback;
  final int pending;
  final int processing;
  final int failed;
  final int skipped;
  final int notAnalyzed;
  final double? averageRating;
  final int positive;
  final int neutral;
  final int negative;
  final int mixed;
  final int unknown;
  final int needsReview;
  final int ratingMismatch;
  final String trendBucket;
  final List<BackendFeedbackSentimentTrendPoint> trend;
  final List<BackendFacilitySentimentInsight> facilities;
  final List<BackendComplaintTopicInsight> complaints;

  factory BackendFeedbackSentimentAnalytics.fromJson(
    Map<String, dynamic> json,
  ) => BackendFeedbackSentimentAnalytics(
    totalFeedback: _int(json['total_feedback']),
    writtenFeedback: _int(json['written_feedback']),
    classifiedFeedback: _int(json['classified_feedback']),
    pending: _int(json['pending']),
    processing: _int(json['processing']),
    failed: _int(json['failed']),
    skipped: _int(json['skipped']),
    notAnalyzed: _int(json['not_analyzed']),
    averageRating: _decimal(json['average_rating']),
    positive: _int(json['positive']),
    neutral: _int(json['neutral']),
    negative: _int(json['negative']),
    mixed: _int(json['mixed']),
    unknown: _int(json['unknown']),
    needsReview: _int(json['needs_review']),
    ratingMismatch: _int(json['rating_mismatch']),
    trendBucket: '${json['trend_bucket'] ?? 'day'}',
    trend: ((json['trend'] as List?) ?? const [])
        .map(
          (row) => BackendFeedbackSentimentTrendPoint.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList(),
    facilities: ((json['facilities'] as List?) ?? const [])
        .map(
          (row) => BackendFacilitySentimentInsight.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList(),
    complaints: ((json['complaints'] as List?) ?? const [])
        .map(
          (row) => BackendComplaintTopicInsight.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList(),
  );

  FeedbackSentimentAnalytics toModel() => FeedbackSentimentAnalytics(
    totalFeedback: totalFeedback,
    writtenFeedback: writtenFeedback,
    classifiedFeedback: classifiedFeedback,
    pending: pending,
    processing: processing,
    failed: failed,
    skipped: skipped,
    notAnalyzed: notAnalyzed,
    averageRating: averageRating,
    positive: positive,
    neutral: neutral,
    negative: negative,
    mixed: mixed,
    unknown: unknown,
    needsReview: needsReview,
    ratingMismatch: ratingMismatch,
    trendBucket: trendBucket,
    trend: [for (final point in trend) point.toModel()],
    facilities: [for (final facility in facilities) facility.toModel()],
    complaints: [for (final complaint in complaints) complaint.toModel()],
  );
}

/// Server-side query object for the admin feedback list, modelled on
/// [AuditQuery].
class FeedbackQuery {
  const FeedbackQuery({
    this.search = '',
    this.facilityId,
    this.minRating,
    this.maxRating,
    this.from,
    this.to,
    this.sentiment,
    this.topic,
    this.analysisStatus,
    this.needsReview,
    this.sort = FeedbackSort.newest,
    this.limit = 50,
    this.offset = 0,
  });

  final String search;
  final String? facilityId;
  final int? minRating;
  final int? maxRating;
  final DateTime? from;
  final DateTime? to;
  final SentimentLabel? sentiment;
  final FeedbackTopic? topic;
  final SentimentAnalysisStatus? analysisStatus;
  final bool? needsReview;
  final FeedbackSort sort;
  final int limit;
  final int offset;

  FeedbackQuery copyWith({
    String? search,
    String? facilityId,
    bool clearFacility = false,
    int? minRating,
    int? maxRating,
    bool clearRatingRange = false,
    DateTime? from,
    DateTime? to,
    bool clearDateRange = false,
    SentimentLabel? sentiment,
    bool clearSentiment = false,
    FeedbackTopic? topic,
    bool clearTopic = false,
    SentimentAnalysisStatus? analysisStatus,
    bool clearAnalysisStatus = false,
    bool? needsReview,
    bool clearNeedsReview = false,
    FeedbackSort? sort,
    int? limit,
    int? offset,
  }) => FeedbackQuery(
    search: search ?? this.search,
    facilityId: clearFacility ? null : (facilityId ?? this.facilityId),
    minRating: clearRatingRange ? null : (minRating ?? this.minRating),
    maxRating: clearRatingRange ? null : (maxRating ?? this.maxRating),
    from: clearDateRange ? null : (from ?? this.from),
    to: clearDateRange ? null : (to ?? this.to),
    sentiment: clearSentiment ? null : (sentiment ?? this.sentiment),
    topic: clearTopic ? null : (topic ?? this.topic),
    analysisStatus: clearAnalysisStatus
        ? null
        : (analysisStatus ?? this.analysisStatus),
    needsReview: clearNeedsReview ? null : (needsReview ?? this.needsReview),
    sort: sort ?? this.sort,
    limit: limit ?? this.limit,
    offset: offset ?? this.offset,
  );

  String get sortParam => switch (sort) {
    FeedbackSort.newest => 'newest',
    FeedbackSort.oldest => 'oldest',
    FeedbackSort.highest => 'highest',
    FeedbackSort.lowest => 'lowest',
  };
}

class BackendLoyaltyTransaction {
  const BackendLoyaltyTransaction({
    required this.id,
    required this.userId,
    required this.points,
    required this.transactionType,
    required this.sourceType,
    this.sourceId,
    this.actorId,
    this.description = '',
    required this.createdAt,
  });

  final String id;
  final String userId;
  final double points;
  final String transactionType;
  final String sourceType;
  final String? sourceId;
  final String? actorId;
  final String description;
  final DateTime createdAt;

  factory BackendLoyaltyTransaction.fromJson(Map<String, dynamic> json) =>
      BackendLoyaltyTransaction(
        id: '${json['id']}',
        userId: '${json['user_id']}',
        points: (json['points'] as num).toDouble(),
        transactionType: '${json['transaction_type']}',
        sourceType: '${json['source_type']}',
        sourceId: json['source_id'] as String?,
        actorId: json['actor_id'] as String?,
        description: '${json['description'] ?? ''}',
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  LoyaltyTransaction toModel() => LoyaltyTransaction(
    id: id,
    userId: userId,
    points: points,
    type: LoyaltyTransactionType.fromRaw(transactionType),
    sourceType: sourceType,
    sourceId: sourceId,
    actorId: actorId,
    description: description,
    createdAt: createdAt,
  );
}

class BackendLoyaltyDiscountOffer {
  const BackendLoyaltyDiscountOffer({
    required this.id,
    required this.name,
    this.description = '',
    required this.requiredPoints,
    required this.discountKind,
    this.fixedAmountCentavos,
    this.percentage,
    this.facilityId,
    this.facilityName,
    required this.validFrom,
    required this.validUntil,
    this.active = true,
    this.affordable = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final double requiredPoints;
  final String discountKind;
  final int? fixedAmountCentavos;
  final double? percentage;
  final String? facilityId;
  final String? facilityName;
  final DateTime validFrom;
  final DateTime validUntil;
  final bool active;
  final bool affordable;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory BackendLoyaltyDiscountOffer.fromJson(Map<String, dynamic> json) =>
      BackendLoyaltyDiscountOffer(
        id: '${json['id']}',
        name: '${json['name'] ?? ''}',
        description: '${json['description'] ?? ''}',
        requiredPoints: (json['required_points'] as num?)?.toDouble() ?? 0,
        discountKind: '${json['discount_kind'] ?? 'fixed_amount'}',
        fixedAmountCentavos: (json['fixed_amount_centavos'] as num?)?.toInt(),
        percentage: (json['percentage'] as num?)?.toDouble(),
        facilityId: json['facility_id'] as String?,
        facilityName: json['facility_name'] as String?,
        validFrom: DateTime.parse('${json['valid_from']}'),
        validUntil: DateTime.parse('${json['valid_until']}'),
        active: json['active'] as bool? ?? true,
        affordable: json['affordable'] as bool? ?? false,
        createdAt: DateTime.parse('${json['created_at']}'),
        updatedAt: DateTime.parse('${json['updated_at']}'),
      );

  LoyaltyDiscountOffer toModel() => LoyaltyDiscountOffer(
    id: id,
    name: name,
    description: description,
    requiredPoints: requiredPoints,
    discountKind: DiscountKind.fromRaw(discountKind),
    fixedAmountCentavos: fixedAmountCentavos,
    percentage: percentage,
    facilityId: facilityId,
    facilityName: facilityName,
    validFrom: validFrom,
    validUntil: validUntil,
    active: active,
    affordable: affordable,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

class BackendLoyaltyDiscountApplication {
  const BackendLoyaltyDiscountApplication({
    required this.id,
    required this.claimId,
    required this.reservationId,
    required this.discountAmountCentavos,
    required this.status,
    required this.appliedAt,
  });

  final String id;
  final String claimId;
  final String reservationId;
  final int discountAmountCentavos;
  final String status;
  final DateTime appliedAt;

  factory BackendLoyaltyDiscountApplication.fromJson(
    Map<String, dynamic> json,
  ) => BackendLoyaltyDiscountApplication(
    id: '${json['id']}',
    claimId: '${json['claim_id']}',
    reservationId: '${json['reservation_id']}',
    discountAmountCentavos:
        (json['discount_amount_centavos'] as num?)?.toInt() ?? 0,
    status: '${json['status'] ?? 'applied'}',
    appliedAt: DateTime.parse('${json['applied_at']}'),
  );

  LoyaltyDiscountApplication toModel() => LoyaltyDiscountApplication(
    id: id,
    claimId: claimId,
    reservationId: reservationId,
    discountAmountCentavos: discountAmountCentavos,
    status: status,
    appliedAt: appliedAt,
  );
}

class BackendLoyaltyDiscountClaim {
  const BackendLoyaltyDiscountClaim({
    required this.id,
    required this.userId,
    required this.offerId,
    required this.offerName,
    this.offerDescription = '',
    required this.discountKind,
    this.fixedAmountCentavos,
    this.percentage,
    this.facilityId,
    this.facilityName,
    required this.requiredPoints,
    required this.expiryDate,
    required this.pointsSpent,
    required this.status,
    required this.claimedAt,
    this.consumedAt,
    this.application,
  });

  final String id;
  final String userId;
  final String offerId;
  final String offerName;
  final String offerDescription;
  final String discountKind;
  final int? fixedAmountCentavos;
  final double? percentage;
  final String? facilityId;
  final String? facilityName;
  final double requiredPoints;
  final DateTime expiryDate;
  final double pointsSpent;
  final String status;
  final DateTime claimedAt;
  final DateTime? consumedAt;
  final BackendLoyaltyDiscountApplication? application;

  factory BackendLoyaltyDiscountClaim.fromJson(Map<String, dynamic> json) {
    final application = json['application'];
    return BackendLoyaltyDiscountClaim(
      id: '${json['id']}',
      userId: '${json['user_id']}',
      offerId: '${json['offer_id']}',
      offerName: '${json['offer_name'] ?? ''}',
      offerDescription: '${json['offer_description'] ?? ''}',
      discountKind: '${json['discount_kind'] ?? 'fixed_amount'}',
      fixedAmountCentavos: (json['fixed_amount_centavos'] as num?)?.toInt(),
      percentage: (json['percentage'] as num?)?.toDouble(),
      facilityId: json['facility_id'] as String?,
      facilityName: json['facility_name'] as String?,
      requiredPoints: (json['required_points'] as num?)?.toDouble() ?? 0,
      expiryDate: DateTime.parse('${json['expiry_date']}'),
      pointsSpent: (json['points_spent'] as num?)?.toDouble() ?? 0,
      status: '${json['effective_status'] ?? json['status'] ?? 'claimed'}',
      claimedAt: DateTime.parse('${json['claimed_at']}'),
      consumedAt: _date(json['consumed_at']),
      application: application is Map
          ? BackendLoyaltyDiscountApplication.fromJson(
              Map<String, dynamic>.from(application),
            )
          : null,
    );
  }

  LoyaltyDiscountClaim toModel() => LoyaltyDiscountClaim(
    id: id,
    userId: userId,
    offerId: offerId,
    offerName: offerName,
    offerDescription: offerDescription,
    discountKind: DiscountKind.fromRaw(discountKind),
    fixedAmountCentavos: fixedAmountCentavos,
    percentage: percentage,
    facilityId: facilityId,
    facilityName: facilityName,
    requiredPoints: requiredPoints,
    expiryDate: expiryDate,
    pointsSpent: pointsSpent,
    status: LoyaltyDiscountClaimStatus.fromRaw(status),
    claimedAt: claimedAt,
    consumedAt: consumedAt,
    application: application?.toModel(),
  );
}

class BackendLoyaltyReward {
  const BackendLoyaltyReward({
    required this.id,
    required this.name,
    this.description = '',
    required this.pointsCost,
    this.active = true,
    this.stock,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final int pointsCost;
  final bool active;
  final int? stock;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory BackendLoyaltyReward.fromJson(Map<String, dynamic> json) =>
      BackendLoyaltyReward(
        id: '${json['id']}',
        name: '${json['name'] ?? ''}',
        description: '${json['description'] ?? ''}',
        pointsCost: (json['points_cost'] as num?)?.toInt() ?? 0,
        active: json['active'] as bool? ?? true,
        stock: (json['stock'] as num?)?.toInt(),
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  LoyaltyReward toModel() => LoyaltyReward(
    id: id,
    name: name,
    description: description,
    pointsCost: pointsCost,
    active: active,
    stock: stock,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

class BackendLoyaltyRedemption {
  const BackendLoyaltyRedemption({
    required this.id,
    required this.userId,
    required this.rewardId,
    required this.rewardName,
    required this.pointsSpent,
    required this.status,
    required this.redemptionCode,
    required this.createdAt,
    this.fulfilledAt,
  });

  final String id;
  final String userId;
  final String rewardId;
  final String rewardName;
  final int pointsSpent;
  final String status;
  final String redemptionCode;
  final DateTime createdAt;
  final DateTime? fulfilledAt;

  factory BackendLoyaltyRedemption.fromJson(Map<String, dynamic> json) =>
      BackendLoyaltyRedemption(
        id: '${json['id']}',
        userId: '${json['user_id']}',
        rewardId: '${json['reward_id']}',
        rewardName: '${json['reward_name'] ?? ''}',
        pointsSpent: (json['points_spent'] as num?)?.toInt() ?? 0,
        status: '${json['status'] ?? 'issued'}',
        redemptionCode: '${json['redemption_code'] ?? ''}',
        createdAt: DateTime.parse(json['created_at'] as String),
        fulfilledAt: _date(json['fulfilled_at']),
      );

  LoyaltyRedemption toModel() => LoyaltyRedemption(
    id: id,
    userId: userId,
    rewardId: rewardId,
    rewardName: rewardName,
    pointsSpent: pointsSpent,
    status: RedemptionStatus.fromRaw(status),
    redemptionCode: redemptionCode,
    createdAt: createdAt,
    fulfilledAt: fulfilledAt,
  );
}

class BackendLoyaltySummary {
  const BackendLoyaltySummary({
    this.eligible = true,
    this.balance = 0,
    this.lifetimeEarned = 0,
    this.lifetimeRedeemed = 0,
    this.rules = const {},
    this.transactions = const [],
    this.redemptions = const [],
    this.rewards = const [],
    this.offers = const [],
    this.claims = const [],
  });

  final bool eligible;
  final double balance;
  final double lifetimeEarned;
  final double lifetimeRedeemed;
  final Map<String, double> rules;
  final List<BackendLoyaltyTransaction> transactions;
  final List<BackendLoyaltyRedemption> redemptions;
  final List<BackendLoyaltyReward> rewards;
  final List<BackendLoyaltyDiscountOffer> offers;
  final List<BackendLoyaltyDiscountClaim> claims;

  factory BackendLoyaltySummary.fromJson(Map<String, dynamic> json) =>
      BackendLoyaltySummary(
        eligible: json['eligible'] as bool? ?? true,
        balance: (json['balance'] as num?)?.toDouble() ?? 0,
        lifetimeEarned: (json['lifetime_earned'] as num?)?.toDouble() ?? 0,
        lifetimeRedeemed: (json['lifetime_redeemed'] as num?)?.toDouble() ?? 0,
        rules: {
          for (final entry
              in (json['rules'] as Map<String, dynamic>? ?? const {}).entries)
            entry.key: (entry.value as num?)?.toDouble() ?? 0,
        },
        transactions: ((json['transactions'] as List?) ?? const [])
            .map(
              (row) => BackendLoyaltyTransaction.fromJson(
                Map<String, dynamic>.from(row as Map),
              ),
            )
            .toList(),
        redemptions: ((json['redemptions'] as List?) ?? const [])
            .map(
              (row) => BackendLoyaltyRedemption.fromJson(
                Map<String, dynamic>.from(row as Map),
              ),
            )
            .toList(),
        rewards: ((json['rewards'] as List?) ?? const [])
            .map(
              (row) => BackendLoyaltyReward.fromJson(
                Map<String, dynamic>.from(row as Map),
              ),
            )
            .toList(),
        offers: ((json['offers'] as List?) ?? const [])
            .map(
              (row) => BackendLoyaltyDiscountOffer.fromJson(
                Map<String, dynamic>.from(row as Map),
              ),
            )
            .toList(),
        claims: ((json['claims'] as List?) ?? const [])
            .map(
              (row) => BackendLoyaltyDiscountClaim.fromJson(
                Map<String, dynamic>.from(row as Map),
              ),
            )
            .toList(),
      );

  LoyaltySummary toModel() => LoyaltySummary(
    eligible: eligible,
    balance: balance,
    lifetimeEarned: lifetimeEarned,
    lifetimeRedeemed: lifetimeRedeemed,
    rules: rules,
    transactions: transactions.map((row) => row.toModel()).toList(),
    redemptions: redemptions.map((row) => row.toModel()).toList(),
    rewards: rewards.map((row) => row.toModel()).toList(),
    offers: offers.map((row) => row.toModel()).toList(),
    claims: claims.map((row) => row.toModel()).toList(),
  );
}

class BackendLoyaltyBalanceRow {
  const BackendLoyaltyBalanceRow({
    required this.userId,
    required this.fullName,
    required this.email,
    required this.balance,
    required this.lifetimeEarned,
    required this.lifetimeRedeemed,
    this.lastActivityAt,
  });

  final String userId;
  final String fullName;
  final String email;
  final double balance;
  final double lifetimeEarned;
  final double lifetimeRedeemed;
  final DateTime? lastActivityAt;

  factory BackendLoyaltyBalanceRow.fromJson(Map<String, dynamic> json) =>
      BackendLoyaltyBalanceRow(
        userId: '${json['user_id']}',
        fullName: '${json['full_name'] ?? ''}',
        email: '${json['email'] ?? ''}',
        balance: (json['balance'] as num?)?.toDouble() ?? 0,
        lifetimeEarned: (json['lifetime_earned'] as num?)?.toDouble() ?? 0,
        lifetimeRedeemed: (json['lifetime_redeemed'] as num?)?.toDouble() ?? 0,
        lastActivityAt: _date(json['last_activity_at']),
      );

  LoyaltyBalanceRow toModel() => LoyaltyBalanceRow(
    userId: userId,
    fullName: fullName,
    email: email,
    balance: balance,
    lifetimeEarned: lifetimeEarned,
    lifetimeRedeemed: lifetimeRedeemed,
    lastActivityAt: lastActivityAt,
  );
}

class BackendLoyaltyAdminClaim {
  const BackendLoyaltyAdminClaim({
    required this.claimId,
    required this.renterUserId,
    required this.renterFullName,
    required this.renterEmail,
    required this.offerId,
    required this.offerName,
    required this.discountKind,
    this.fixedAmountCentavos,
    this.percentage,
    this.facilityId,
    this.facilityName,
    required this.pointsSpent,
    required this.expiryDate,
    required this.status,
    required this.effectiveStatus,
    this.applicationId,
    this.applicationStatus,
    this.releaseReason,
    this.appliedAt,
    this.releasedAt,
    this.applicationConsumedAt,
    this.reservationId,
    required this.claimedAt,
    this.consumedAt,
    required this.createdAt,
  });

  final String claimId;
  final String renterUserId;
  final String renterFullName;
  final String renterEmail;
  final String offerId;
  final String offerName;
  final String discountKind;
  final int? fixedAmountCentavos;
  final double? percentage;
  final String? facilityId;
  final String? facilityName;
  final double pointsSpent;
  final DateTime expiryDate;
  final String status;
  final String effectiveStatus;
  final String? applicationId;
  final String? applicationStatus;
  final String? releaseReason;
  final DateTime? appliedAt;
  final DateTime? releasedAt;
  final DateTime? applicationConsumedAt;
  final String? reservationId;
  final DateTime claimedAt;
  final DateTime? consumedAt;
  final DateTime createdAt;

  factory BackendLoyaltyAdminClaim.fromJson(Map<String, dynamic> json) =>
      BackendLoyaltyAdminClaim(
        claimId: '${json['claim_id']}',
        renterUserId: '${json['renter_user_id']}',
        renterFullName: '${json['renter_full_name'] ?? ''}',
        renterEmail: '${json['renter_email'] ?? ''}',
        offerId: '${json['offer_id']}',
        offerName: '${json['offer_name'] ?? ''}',
        discountKind: '${json['discount_kind'] ?? 'fixed_amount'}',
        fixedAmountCentavos: (json['fixed_amount_centavos'] as num?)?.toInt(),
        percentage: (json['percentage'] as num?)?.toDouble(),
        facilityId: json['facility_id'] as String?,
        facilityName: json['facility_name'] as String?,
        pointsSpent: (json['points_spent'] as num?)?.toDouble() ?? 0,
        expiryDate: DateTime.parse('${json['expiry_date']}'),
        status: '${json['status'] ?? 'claimed'}',
        effectiveStatus: '${json['effective_status'] ?? 'claimed'}',
        applicationId: json['application_id'] as String?,
        applicationStatus: json['application_status'] as String?,
        releaseReason: json['release_reason'] as String?,
        appliedAt: _date(json['applied_at']),
        releasedAt: _date(json['released_at']),
        applicationConsumedAt: _date(json['application_consumed_at']),
        reservationId: json['reservation_id'] as String?,
        claimedAt: DateTime.parse('${json['claimed_at']}'),
        consumedAt: _date(json['consumed_at']),
        createdAt: DateTime.parse('${json['created_at']}'),
      );

  LoyaltyAdminClaimRow toModel() => LoyaltyAdminClaimRow(
    claimId: claimId,
    renterUserId: renterUserId,
    renterFullName: renterFullName,
    renterEmail: renterEmail,
    offerId: offerId,
    offerName: offerName,
    discountKind: DiscountKind.fromRaw(discountKind),
    fixedAmountCentavos: fixedAmountCentavos,
    percentage: percentage,
    facilityId: facilityId,
    facilityName: facilityName,
    pointsSpent: pointsSpent,
    expiryDate: expiryDate,
    status: LoyaltyDiscountClaimStatus.fromRaw(status),
    effectiveStatus: LoyaltyDiscountClaimStatus.fromRaw(effectiveStatus),
    applicationId: applicationId,
    applicationStatus: applicationStatus,
    releaseReason: releaseReason,
    appliedAt: appliedAt,
    releasedAt: releasedAt,
    applicationConsumedAt: applicationConsumedAt,
    reservationId: reservationId,
    claimedAt: claimedAt,
    consumedAt: consumedAt,
    createdAt: createdAt,
  );
}

class BackendAssistantConversation {
  const BackendAssistantConversation({
    required this.id,
    required this.title,
    required this.activeDraft,
    required this.createdAt,
    required this.lastActivityAt,
  });

  final String id;
  final String title;
  final Map<String, dynamic> activeDraft;
  final DateTime createdAt;
  final DateTime lastActivityAt;

  factory BackendAssistantConversation.fromJson(Map<String, dynamic> json) =>
      BackendAssistantConversation(
        id: '${json['id']}',
        title: '${json['title'] ?? 'New chat'}',
        activeDraft: Map<String, dynamic>.from(
          json['active_draft'] as Map? ?? const <String, dynamic>{},
        ),
        createdAt: DateTime.parse('${json['created_at']}'),
        lastActivityAt: DateTime.parse('${json['last_activity_at']}'),
      );
}

class BackendAssistantMessage {
  const BackendAssistantMessage({
    required this.id,
    required this.sender,
    required this.messageType,
    required this.text,
    required this.payload,
    required this.createdAt,
    this.reservationId,
    this.action,
  });

  final String id;
  final String sender;
  final String messageType;
  final String text;
  final Map<String, dynamic> payload;
  final String? reservationId;
  final String? action;
  final DateTime createdAt;

  factory BackendAssistantMessage.fromJson(Map<String, dynamic> json) =>
      BackendAssistantMessage(
        id: '${json['id']}',
        sender: '${json['sender']}',
        messageType: '${json['message_type']}',
        text: '${json['text'] ?? ''}',
        payload: Map<String, dynamic>.from(
          json['payload'] as Map? ?? const <String, dynamic>{},
        ),
        reservationId: json['reservation_id'] as String?,
        action: json['action'] as String?,
        createdAt: DateTime.parse('${json['created_at']}'),
      );
}

abstract interface class SmartReserveBackend {
  User? get user;
  Stream<AuthState> get authChanges;
  Future<void> signIn(String email, String password);
  Future<SessionProfile> signInAndLoadProfile(String email, String password);
  Future<void> requestPasswordReset(String email);
  Future<void> verifyPasswordResetCode({
    required String email,
    required String code,
  });
  Future<void> updatePassword(String password);
  Future<SessionProfile> createExternalGuestAccount({
    required String fullName,
    required String email,
    required String password,
  });
  Future<void> signOut();
  Future<SessionProfile?> currentProfile();
  Future<void> completeGuestOnboarding();
  Future<SessionProfile> completeInitialPasswordChange(String password);
  Future<BackendVerification> submitVerification({
    required String claimType,
    required String campusId,
    required String unit,
    required String documentName,
    required String mimeType,
    required Uint8List bytes,
  });
  Future<BackendVerification?> currentVerification();
  Future<List<BackendVerification>> verifications();
  Stream<List<BackendVerification>> verificationStream();
  Future<Uint8List> downloadDocument(String path);
  Future<void> decideVerification({
    required String submissionId,
    required String decision,
    String? reason,
  });
  Future<List<BackendReservation>> reservations();
  Stream<List<BackendReservation>> reservationStream();
  Future<List<BackendBusyWindow>> facilityBusyWindows({
    required List<String> facilityIds,
    required DateTime from,
    required DateTime to,
  });
  Future<List<BackendPublicReservationSlot>> publicReservationCalendar({
    required List<String> facilityIds,
    required DateTime from,
    required DateTime to,
  });
  Future<BackendReservation> submitReservation(ReservationDraft draft);
  Future<ReservationActionResult> performReservationAction(
    ReservationActionCommand command,
  );
  Future<ReservationActionResult> bulkApproveReservations(
    List<BackendReservation> reservations,
  );
  Future<List<BackendAssistantConversation>> assistantConversations();
  Future<BackendAssistantConversation> createAssistantConversation({
    required String title,
    Map<String, dynamic> activeDraft,
  });
  Future<List<BackendAssistantMessage>> assistantMessages(
    String conversationId,
  );
  Future<void> appendAssistantMessages(
    String conversationId,
    List<BackendAssistantMessage> messages,
  );
  Future<void> updateAssistantConversation(
    String conversationId, {
    String? title,
    Map<String, dynamic>? activeDraft,
  });
  Future<void> undoReservationAction(String actionId);
  Future<String> reservationAttachmentUrl(String path);
  Future<List<BackendNotification>> notifications();
  Stream<List<BackendNotification>> notificationStream();
  Future<void> markNotificationRead(String notificationId);
  Future<AnomalyPage> anomalyCenter({
    required AnomalyFilters filters,
    Map<String, dynamic>? cursor,
    int limit,
  });
  Future<AnomalyDetail> anomalyDetail(String anomalyId);
  Future<AnomalyDetail> transitionReservationAnomaly({
    required String anomalyId,
    required String action,
    String? reasonCode,
    String? note,
  });
  Future<RenterRiskSummary> reservationRiskSummary(String requestId);
  Future<RenterRiskSummary> evaluateReservationRiskNow(String requestId);
  Future<void> correctOccurrenceAttendance({
    required String occurrenceId,
    required String targetStage,
    required String reason,
  });
  Future<List<Map<String, dynamic>>> checkMyReservationOverlaps({
    required List<DateTime> startsAt,
    required List<DateTime> endsAt,
    String? excludeRequestId,
  });
  Future<Map<String, bool>> notificationPreferences();
  Future<void> saveNotificationPreferences(Map<String, bool> preferences);
  Future<void> inviteAdmin({
    required String email,
    required String role,
    String? note,
  });
  Future<List<BackendAccount>> accounts();
  Future<List<BackendAccount>> externalClients();
  Stream<List<BackendAccount>> accountStream();
  Future<BackendAccount> inviteAccountAdmin({
    required String email,
    required String role,
    String? note,
    String? organizationSlotId,
  });
  Future<BackendCreatedAccount> createAdministrator({
    required String email,
    required String role,
    String? note,
  });
  Future<BackendCreatedAccount> createOrganizationRepresentative({
    required String fullName,
    required String email,
    required String organizationSlotId,
  });
  Future<BackendCreatedAccount> resetOrganizationRepresentativePassword(
    String accountId,
  );
  Future<List<BackendOrganizationUnit>> organizationUnits();
  Future<List<BackendOrganizationAccountSlot>> organizationSlots();
  Future<BackendOrganizationUnit> createOrganizationUnit({
    String? parentId,
    required String name,
    String? code,
    required String unitType,
    required bool requiresRepresentative,
    String? bookingAudience,
  });
  Future<BackendOrganizationUnit> updateOrganizationUnit({
    required String unitId,
    String? parentId,
    required String name,
    String? code,
    required String unitType,
    String? bookingAudience,
  });
  Future<BackendOrganizationUnit> archiveOrganizationUnit(String unitId);
  Future<BackendAccount> assignOrganizationRepresentative({
    required String profileId,
    required String slotId,
  });
  Future<BackendAccount> transferOrganizationRepresentative({
    required String currentProfileId,
    required String replacementProfileId,
    required String slotId,
  });
  Future<BackendAccount> removeOrganizationRepresentative(String profileId);
  Future<BackendAccount> convertLegacyAccountToExternalGuest({
    required String profileId,
    required String reason,
  });
  Future<BackendAccount> resendAdminInvite(String accountId);
  Future<String> revokeAdminInvite(String accountId);
  Future<BackendAccount> changeAccountRole({
    required String accountId,
    required String role,
  });
  Future<BackendAccount> suspendUserAccount({
    required String accountId,
    required String reason,
    DateTime? suspendedUntil,
  });
  Future<BackendAccount> liftUserSuspension(String accountId);
  Future<BackendAccount> requestAccountReverification(String accountId);
  Future<BackendAccount> sendAccountPasswordReset(String accountId);
  Future<List<BackendFacility>> facilities();
  Stream<List<BackendFacility>> facilityStream();
  Future<BackendFacility> saveFacility(
    FacilityDraft draft, {
    String? editingId,
  });
  Future<void> archiveFacility(String id);
  Future<void> restoreFacility(String id);
  Future<ReportSnapshot> adminReport(ReportScope scope);
  Future<AuditPage> auditEntries(AuditQuery query);
  Future<void> recordAuditExport(AuditQuery query, int rowCount);
  Future<void> revertAuditEntry(String entryId, String reason);
  Future<void> requestReservationSignature(String requestId);
  Future<void> submitReservationSignature({
    required String signatureRequestId,
    required String requestId,
    required ReservationUpload signature,
  });
  Future<void> updateExternalPermitDetails(
    String requestId,
    ExternalPermitDetails details,
  );
  Future<void> uploadOfficialSignature(
    OfficialSignatureSlot slot,
    ReservationUpload signature,
  );
  Future<Map<String, dynamic>> previewOfficialSignature(
    OfficialSignatureSlot slot,
  );
  String facilityPhotoUrl(String path);
}

abstract interface class SmartReserveCoreBackend {
  Future<BackendReservationQuote> reservationQuote({
    required String facilityId,
    required List<DateTime> startsAt,
    required List<DateTime> endsAt,
    required int headcount,
    List<String> amenityIds,
    String? discountClaimId,
  });
  Future<PaymentSummary> paymentSummary(String requestId);
  Future<List<PaymentTransaction>> payments(String requestId);
  Future<PaymentTransaction> submitPayment(PaymentSubmissionDraft draft);
  Future<PaymentTransaction> correctPaymentSubmission({
    required PaymentTransaction payment,
    required int amountCentavos,
    required String referenceNumber,
    required ReservationUpload proof,
  });
  Future<PaymentTransaction> decidePayment({
    required String paymentId,
    required String decision,
    String? reason,
  });
  Future<String> paymentProofUrl(String path);
  Future<void> submitReservationUseAssessment({
    required String requestId,
    required String occurrenceId,
    required int cleanlinessRating,
    required int equipmentConditionRating,
    required bool leftUnclean,
    required bool equipmentDamaged,
    required String comment,
    List<ReservationUpload> evidence,
  });
  Future<ReservationPermit?> ensurePermit(String requestId);
  Future<PermitReadiness> permitReadiness(String requestId);
  Future<Uint8List> downloadPermitPdf(String path);
  Future<Uint8List> previewPermit(String requestId);
  Future<Map<String, dynamic>> verifyPermit(String token);
  Future<void> saveFacilityConfiguration(FacilityConfigurationDraft draft);
  Future<List<AuditEntry>> facilityActivity(String facilityId);

  Future<BackendFeedback> submitFeedback({
    required String reservationId,
    required int rating,
    String comment,
    int? cleanliness,
    int? condition,
    int? equipment,
  });
  Future<BackendFeedbackPage> feedbackEntries(FeedbackQuery query);
  Future<BackendFeedbackSummary> feedbackSummary(FeedbackQuery query);
  Future<BackendFeedbackSentimentAnalytics> feedbackSentimentAnalytics(
    FeedbackQuery query,
  );
  Future<BackendFeedbackSentimentAnalysis?> retryFeedbackSentiment(
    String feedbackId,
  );
  Stream<void> feedbackSentimentAnalysisStream();
  Future<BackendLoyaltySummary> loyaltySummary();
  Stream<List<BackendLoyaltyTransaction>> loyaltyTransactionStream();
  Future<BackendLoyaltyRedemption> redeemLoyaltyReward(String rewardId);
  Future<BackendLoyaltyDiscountClaim> claimLoyaltyDiscount(String offerId);
  Future<List<BackendLoyaltyBalanceRow>> loyaltyBalances({
    String search,
    int limit,
  });
  Future<List<BackendLoyaltyTransaction>> loyaltyLedger(
    String userId, {
    int limit,
  });
  Future<List<BackendLoyaltyRedemption>> loyaltyRedemptions({
    String? userId,
    int limit,
  });
  Future<List<BackendLoyaltyAdminClaim>> loyaltyAdminClaims({
    String search,
    String? status,
    int limit,
  });
  Future<List<BackendLoyaltyDiscountOffer>> loyaltyDiscountOffers();
  Future<BackendLoyaltyDiscountOffer> saveLoyaltyDiscountOffer({
    String? id,
    required String name,
    String description,
    required double requiredPoints,
    required DiscountKind discountKind,
    int? fixedAmountCentavos,
    double? percentage,
    String? facilityId,
    required DateTime validFrom,
    required DateTime validUntil,
    bool active,
  });
  Future<void> setLoyaltyDiscountOfferActive(String offerId, bool active);
  Future<BackendLoyaltyTransaction> adjustLoyaltyPoints({
    required String userId,
    required double points,
    required String reason,
  });
}

FacilityAmenity _facilityAmenity(Map<String, dynamic> json) => FacilityAmenity(
  id: '${json['id']}',
  name: '${json['name'] ?? ''}',
  description: '${json['description'] ?? ''}',
  priceCentavos: (json['price_centavos'] as num?)?.toInt() ?? 0,
  pricingUnit: '${json['pricing_unit'] ?? 'per_occurrence'}',
  enabled: json['enabled'] as bool? ?? true,
  internalPermitRowCode: json['internal_permit_row_code'] as String?,
  externalPermitRowCode: json['external_permit_row_code'] as String?,
  permitQuantityRequired: json['permit_quantity_required'] as bool? ?? false,
);

FacilityPaymentMethod _facilityPaymentMethod(Map<String, dynamic> json) =>
    FacilityPaymentMethod(
      id: '${json['id']}',
      facilityId: '${json['facility_id']}',
      accountName: '${json['account_name'] ?? ''}',
      accountNumber: '${json['account_number'] ?? ''}',
      instructions: '${json['instructions'] ?? ''}',
      methodType: '${json['method_type'] ?? 'gcash'}',
      enabled: json['enabled'] as bool? ?? true,
    );

class BackendFacility {
  const BackendFacility({
    required this.id,
    required this.name,
    required this.room,
    required this.building,
    required this.category,
    required this.capacity,
    required this.status,
    required this.pinConfidence,
    required this.campusName,
    required this.floor,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.confirmedOutside,
    required this.description,
    required this.geoBuilding,
    required this.street,
    required this.barangay,
    required this.municipality,
    required this.province,
    required this.region,
    required this.country,
    required this.geoEdited,
    required this.amenities,
    required this.photoPaths,
    required this.requiresApproval,
    required this.publicListing,
    required this.openDays,
    required this.openTime,
    required this.closeTime,
    required this.maxDuration,
    required this.advanceBooking,
    required this.bookingBuffer,
    required this.bookingCount,
    required this.updatedByName,
    required this.updatedAt,
    this.maxDurationMinutes = 240,
    this.advanceBookingDays = 30,
    this.bookingBufferMinutes = 15,
    this.amenityOptions = const [],
    this.paymentMethods = const [],
    this.audienceRates = const [],
    this.canManage = false,
    this.bookableForCurrentUser = true,
    this.supportsInternalLane = true,
    this.supportsExternalLane = true,
    this.bookingBlockReason,
    this.facilityClassification = 'shared',
    this.depositWindowMinutes = 1440,
    this.balanceDueLeadDays = 3,
    this.balanceDueLeadMinutes = 1440,
    this.paymentCorrectionWindowMinutes = 1440,
    this.downPaymentPercent = 50,
    this.ratingAverage,
    this.ratingCount = 0,
    this.internalPermitRowCode,
    this.externalPermitRowCode,
  });

  final String id;
  final String name;
  final String room;
  final String building;
  final String category;
  final int capacity;
  final String status;
  final String pinConfidence;
  final String campusName;
  final String floor;
  final double? latitude;
  final double? longitude;
  final int? accuracy;
  final bool confirmedOutside;
  final String description;
  final String geoBuilding;
  final String street;
  final String barangay;
  final String municipality;
  final String province;
  final String region;
  final String country;
  final List<String> geoEdited;
  final List<String> amenities;
  final List<String> photoPaths;
  final bool requiresApproval;
  final bool publicListing;
  final List<bool> openDays;
  final String openTime;
  final String closeTime;
  final String maxDuration;
  final String advanceBooking;
  final String bookingBuffer;
  final int bookingCount;
  final String updatedByName;
  final DateTime updatedAt;
  final int maxDurationMinutes;
  final int advanceBookingDays;
  final int bookingBufferMinutes;
  final List<FacilityAmenity> amenityOptions;
  final List<FacilityPaymentMethod> paymentMethods;
  final List<FacilityAudienceRate> audienceRates;
  final bool canManage;
  final bool bookableForCurrentUser;
  final bool supportsInternalLane;
  final bool supportsExternalLane;
  final FacilityBookingBlockReason? bookingBlockReason;
  final String facilityClassification;
  final int depositWindowMinutes;
  final int balanceDueLeadDays;
  final int balanceDueLeadMinutes;
  final int paymentCorrectionWindowMinutes;
  final int downPaymentPercent;
  final double? ratingAverage;
  final int ratingCount;
  final String? internalPermitRowCode;
  final String? externalPermitRowCode;

  factory BackendFacility.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) =>
        ((json[key] as List?) ?? const []).map((e) => '$e').toList();
    final days = ((json['open_days'] as List?) ?? const [])
        .map((e) => e == true)
        .toList();
    String clock(String key) {
      final value = (json[key] as String?) ?? '';
      return value.length >= 5 ? value.substring(0, 5) : value;
    }

    return BackendFacility(
      id: json['id'] as String,
      name: '${json['name'] ?? ''}',
      room: '${json['room'] ?? ''}',
      building: '${json['building'] ?? ''}',
      category: '${json['category'] ?? ''}',
      capacity: (json['capacity'] as num).toInt(),
      status: '${json['status'] ?? 'draft'}',
      pinConfidence: '${json['pin_confidence'] ?? 'none'}',
      campusName: '${json['campus_name'] ?? campus.name}',
      floor: '${json['floor'] ?? ''}',
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      accuracy: (json['accuracy'] as num?)?.toInt(),
      confirmedOutside: json['confirmed_outside'] as bool? ?? false,
      description: '${json['description'] ?? ''}',
      geoBuilding: '${json['geo_building'] ?? ''}',
      street: '${json['street'] ?? ''}',
      barangay: '${json['barangay'] ?? ''}',
      municipality: '${json['municipality'] ?? ''}',
      province: '${json['province'] ?? ''}',
      region: '${json['region'] ?? ''}',
      country: '${json['country'] ?? ''}',
      geoEdited: strings('geo_edited'),
      amenities: strings('amenities'),
      photoPaths: strings('photo_paths'),
      requiresApproval: json['requires_approval'] as bool? ?? true,
      publicListing: json['public_listing'] as bool? ?? true,
      openDays: days.length == 7
          ? days
          : const [true, true, true, true, true, false, false],
      openTime: clock('open_time'),
      closeTime: clock('close_time'),
      maxDuration: '${json['max_duration'] ?? '4 hours'}',
      advanceBooking: '${json['advance_booking'] ?? '30 days ahead'}',
      bookingBuffer: '${json['booking_buffer'] ?? '15 minutes'}',
      bookingCount: (json['booking_count'] as num?)?.toInt() ?? 0,
      updatedByName: '${json['updated_by_name'] ?? 'Administrator'}',
      updatedAt: DateTime.parse(json['updated_at'] as String),
      maxDurationMinutes:
          (json['max_duration_minutes'] as num?)?.toInt() ?? 240,
      advanceBookingDays: (json['advance_booking_days'] as num?)?.toInt() ?? 30,
      bookingBufferMinutes:
          (json['booking_buffer_minutes'] as num?)?.toInt() ?? 15,
      amenityOptions: [
        for (final raw in (json['facility_amenities'] as List? ?? const []))
          _facilityAmenity(Map<String, dynamic>.from(raw as Map)),
      ],
      paymentMethods: [
        for (final raw
            in (json['facility_payment_methods'] as List? ?? const []))
          _facilityPaymentMethod(Map<String, dynamic>.from(raw as Map)),
      ],
      audienceRates: [
        for (final raw in (json['facility_rates'] as List? ?? const []))
          FacilityAudienceRate(
            audience: '${(raw as Map)['audience']}',
            hourlyRateCentavos:
                (raw['hourly_rate_centavos'] as num?)?.toInt() ?? 0,
            enabled: raw['enabled'] as bool? ?? true,
          ),
      ],
      facilityClassification: '${json['facility_classification'] ?? 'shared'}',
      depositWindowMinutes:
          (json['deposit_window_minutes'] as num?)?.toInt() ?? 1440,
      balanceDueLeadDays: (json['balance_due_lead_days'] as num?)?.toInt() ?? 3,
      balanceDueLeadMinutes:
          (json['balance_due_lead_minutes'] as num?)?.toInt() ?? 1440,
      paymentCorrectionWindowMinutes:
          (json['payment_correction_window_minutes'] as num?)?.toInt() ?? 1440,
      downPaymentPercent: (json['down_payment_percent'] as num?)?.toInt() ?? 50,
      ratingAverage: _decimal(
        _embeddedOne(json['facility_rating_stats'])?['rating_average'],
      ),
      ratingCount:
          (_embeddedOne(json['facility_rating_stats'])?['rating_count'] as num?)
              ?.toInt() ??
          0,
      internalPermitRowCode: json['internal_permit_row_code'] as String?,
      externalPermitRowCode: json['external_permit_row_code'] as String?,
    );
  }

  BackendFacility withAccess(Map<String, dynamic>? access) => BackendFacility(
    id: id,
    name: name,
    room: room,
    building: building,
    category: category,
    capacity: capacity,
    status: status,
    pinConfidence: pinConfidence,
    campusName: campusName,
    floor: floor,
    latitude: latitude,
    longitude: longitude,
    accuracy: accuracy,
    confirmedOutside: confirmedOutside,
    description: description,
    geoBuilding: geoBuilding,
    street: street,
    barangay: barangay,
    municipality: municipality,
    province: province,
    region: region,
    country: country,
    geoEdited: geoEdited,
    amenities: amenities,
    photoPaths: photoPaths,
    requiresApproval: requiresApproval,
    publicListing: publicListing,
    openDays: openDays,
    openTime: openTime,
    closeTime: closeTime,
    maxDuration: maxDuration,
    advanceBooking: advanceBooking,
    bookingBuffer: bookingBuffer,
    bookingCount: bookingCount,
    updatedByName: updatedByName,
    updatedAt: updatedAt,
    maxDurationMinutes: maxDurationMinutes,
    advanceBookingDays: advanceBookingDays,
    bookingBufferMinutes: bookingBufferMinutes,
    amenityOptions: amenityOptions,
    paymentMethods: paymentMethods,
    audienceRates: audienceRates,
    canManage: access?['can_manage'] as bool? ?? false,
    bookableForCurrentUser: access?['bookable'] as bool? ?? false,
    supportsInternalLane: access?['supports_internal'] as bool? ?? false,
    supportsExternalLane: access?['supports_external'] as bool? ?? false,
    bookingBlockReason: FacilityBookingBlockReason.fromCode(
      access?['booking_unavailability_code'] as String?,
    ),
    facilityClassification: facilityClassification,
    depositWindowMinutes: depositWindowMinutes,
    balanceDueLeadDays: balanceDueLeadDays,
    balanceDueLeadMinutes: balanceDueLeadMinutes,
    paymentCorrectionWindowMinutes: paymentCorrectionWindowMinutes,
    downPaymentPercent: downPaymentPercent,
    ratingAverage: ratingAverage,
    ratingCount: ratingCount,
    internalPermitRowCode: internalPermitRowCode,
    externalPermitRowCode: externalPermitRowCode,
  );

  Facility toFacility(String Function(String path) publicUrlFor) {
    final coords = latitude == null || longitude == null
        ? null
        : LatLng(latitude!, longitude!);
    final photos = [
      for (final path in photoPaths)
        FacilityPhoto.remote(storagePath: path, publicUrl: publicUrlFor(path)),
    ];
    return Facility(
      id: id,
      name: name,
      room: room,
      building: building,
      category: category,
      capacity: capacity,
      pinConfidence: switch (pinConfidence) {
        'verified' => PinConfidence.verified,
        'needs_check' => PinConfidence.needsCheck,
        _ => PinConfidence.none,
      },
      state: switch (status) {
        'active' => FacilityState.active,
        'under_review' => FacilityState.underReview,
        'maintenance' => FacilityState.maintenance,
        _ => FacilityState.draft,
      },
      floor: floor,
      coords: coords,
      accuracy: accuracy,
      description: description,
      amenities: amenities,
      hours: '$openTime–$closeTime',
      days: _daysLabel(openDays),
      approvalRequired: requiresApproval,
      maxDuration: maxDuration,
      advance: advanceBooking,
      buffer: bookingBuffer,
      publicListing: publicListing,
      campusName: campusName,
      updated: '${_shortDate(updatedAt.toLocal())} · $updatedByName',
      bookings: bookingCount,
      photoCount: photos.length,
      photos: photos,
      confirmedOutside: confirmedOutside,
      geoBuilding: geoBuilding,
      street: street,
      barangay: barangay,
      municipality: municipality,
      province: province,
      region: region,
      country: country,
      geoEdited: geoEdited,
      maxDurationMinutes: maxDurationMinutes,
      advanceBookingDays: advanceBookingDays,
      bookingBufferMinutes: bookingBufferMinutes,
      amenityOptions: amenityOptions,
      paymentMethods: paymentMethods,
      audienceRates: audienceRates,
      canManage: canManage,
      bookableForCurrentUser: bookableForCurrentUser,
      supportsInternalLane: supportsInternalLane,
      supportsExternalLane: supportsExternalLane,
      bookingBlockReason: bookingBlockReason,
      facilityClassification: facilityClassification,
      depositWindowMinutes: depositWindowMinutes,
      balanceDueLeadDays: balanceDueLeadDays,
      balanceDueLeadMinutes: balanceDueLeadMinutes,
      paymentCorrectionWindowMinutes: paymentCorrectionWindowMinutes,
      downPaymentPercent: downPaymentPercent,
      ratingAverage: ratingAverage,
      ratingCount: ratingCount,
      internalPermitRowCode: internalPermitRowCode,
      externalPermitRowCode: externalPermitRowCode,
    );
  }

  static String _daysLabel(List<bool> days) {
    final enabled = [
      for (var i = 0; i < days.length; i++)
        if (days[i]) dayLabels[i],
    ];
    if (enabled.isEmpty) return 'No days selected';
    if (enabled.length == 7) return 'Mon–Sun';
    final first = days.indexOf(true);
    final last = days.lastIndexOf(true);
    final contiguous = [
      for (var i = first; i <= last; i++) days[i],
    ].every((value) => value);
    return contiguous && enabled.length > 2
        ? '${dayLabels[first]}–${dayLabels[last]}'
        : enabled.join(', ');
  }

  static String _shortDate(DateTime value) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${value.day} ${months[value.month - 1]} ${value.year}';
  }
}

class SupabaseService implements SmartReserveBackend, SmartReserveCoreBackend {
  SupabaseService(this._client);

  final SupabaseClient _client;

  User? get user => _client.auth.currentUser;
  Stream<AuthState> get authChanges => _client.auth.onAuthStateChange;

  Future<void> signIn(String email, String password) =>
      _client.auth.signInWithPassword(email: email, password: password);

  @override
  Future<void> requestPasswordReset(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(email);
    } catch (error) {
      throw classifyAuthFailure(error);
    }
  }

  @override
  Future<void> verifyPasswordResetCode({
    required String email,
    required String code,
  }) async {
    try {
      await _client.auth.verifyOTP(
        email: email,
        token: code,
        type: OtpType.recovery,
      );
    } catch (error) {
      throw classifyAuthFailure(error);
    }
  }

  @override
  Future<void> updatePassword(String password) async {
    try {
      await _client.auth.updateUser(UserAttributes(password: password));
    } catch (error) {
      throw classifyAuthFailure(error);
    }
  }

  @override
  Future<SessionProfile> signInAndLoadProfile(
    String email,
    String password,
  ) async {
    var sessionEstablished = false;
    try {
      await signIn(email, password);
      sessionEstablished = user != null;
      final profile = await currentProfile();
      if (profile == null) {
        throw const AuthSessionException(kind: AuthFailureKind.profileMissing);
      }
      return profile;
    } catch (error) {
      final failure = classifyAuthFailure(error);
      if (sessionEstablished &&
          failure.kind != AuthFailureKind.invalidCredentials &&
          failure.kind != AuthFailureKind.emailUnconfirmed) {
        try {
          await signOut();
        } catch (_) {
          // The local client will still clear the session when it is recreated.
        }
      }
      throw failure;
    }
  }

  @override
  Future<SessionProfile> createExternalGuestAccount({
    required String fullName,
    required String email,
    required String password,
  }) async {
    try {
      final response = await _client.auth.signUp(
        email: email,
        password: password,
        data: {'full_name': fullName},
      );
      if (response.session == null || user == null) {
        throw const AuthSessionException(
          kind: AuthFailureKind.emailConfirmationRequired,
        );
      }
      final profile = await currentProfile();
      if (profile == null) {
        throw const AuthSessionException(kind: AuthFailureKind.profileMissing);
      }
      return profile;
    } catch (error) {
      throw classifyAuthFailure(error);
    }
  }

  Future<void> signOut() => _client.auth.signOut();

  Future<SessionProfile?> currentProfile() async {
    final currentUser = user;
    if (currentUser == null) return null;
    dynamic row;
    try {
      row = await _client.rpc('get_my_session_profile');
    } on PostgrestException catch (error) {
      // Older hosted prototype deployments predate the session-profile RPC.
      // Keep existing sessions usable during a rolling client/database release;
      // new deployments always use the stable RPC above.
      if (error.code != 'PGRST202' && error.code != '42883') rethrow;
      return _legacyCurrentProfile(currentUser);
    }
    if (row == null) return null;
    if (row is! Map) {
      throw _profileContractFailure(
        StateError('Session profile returned an invalid response.'),
      );
    }
    return _parseSessionProfile(Map<String, dynamic>.from(row));
  }

  SessionProfile _parseSessionProfile(Map<String, dynamic> row) {
    try {
      return SessionProfile.fromJson(row);
    } on FormatException catch (error) {
      // A valid account paired with an unparseable row means the client and
      // database profile contracts were deployed out of sync.
      throw _profileContractFailure(error);
    }
  }

  Future<SessionProfile?> _legacyCurrentProfile(User currentUser) async {
    try {
      await _client.rpc('normalize_my_expired_suspension');
      final row = await _client
          .from('profiles')
          .select(
            '*,organization_account_slots(id,label,unit_id,organizational_units(id,name,code,unit_type,booking_audience,requires_representative))',
          )
          .eq('id', currentUser.id)
          .maybeSingle();
      if (row == null) return null;
      final json = Map<String, dynamic>.from(row);
      final slot = json['organization_account_slots'];
      if (slot is Map) {
        final slotJson = Map<String, dynamic>.from(slot);
        final unit = slotJson['organizational_units'];
        if (unit is Map) {
          final unitJson = Map<String, dynamic>.from(unit);
          json['organization_slot_label'] = slotJson['label'];
          json['organization_unit_id'] = unitJson['id'] ?? slotJson['unit_id'];
          json['organization_unit_name'] = unitJson['name'];
          json['organization_unit_code'] = unitJson['code'];
          json['organization_unit_type'] = unitJson['unit_type'];
          json['organization_unit_booking_audience'] =
              unitJson['booking_audience'];
        }
      }
      return _parseSessionProfile(json);
    } on PostgrestException catch (error) {
      // A project that predates the organization-account migrations cannot
      // expose the relationship or the suspension helper. Its base profile is
      // still sufficient to restore an Internal Admin session while it is
      // upgraded. Do not hide permission failures behind this compatibility
      // path.
      if (!_isProfileContractError(error)) {
        rethrow;
      }
    }

    dynamic baseRow;
    try {
      baseRow = await _client
          .from('profiles')
          .select()
          .eq('id', currentUser.id)
          .maybeSingle();
    } on PostgrestException catch (error) {
      if (_isProfileContractError(error)) {
        throw _profileContractFailure(error, code: error.code);
      }
      rethrow;
    }
    if (baseRow == null) return null;
    if (baseRow is! Map) {
      throw _profileContractFailure(
        StateError('Legacy session profile returned an invalid response.'),
      );
    }
    return _parseSessionProfile(Map<String, dynamic>.from(baseRow));
  }

  Future<void> completeGuestOnboarding() async {
    if (user == null) throw const AuthException('Please sign in again.');
    await _client.rpc('complete_guest_onboarding');
  }

  Future<SessionProfile> completeInitialPasswordChange(String password) async {
    if (user == null) throw const AuthException('Please sign in again.');
    late final FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        'complete-initial-password',
        body: {'password': password},
      );
    } on FunctionException catch (error) {
      throw classifyAuthFailure(
        AccountManagementException.fromFunctionException(error),
      );
    }
    final data = response.data;
    if (data is! Map) {
      throw AccountManagementException.invalidResponse(status: response.status);
    }
    final json = Map<String, dynamic>.from(data);
    if (json['error'] != null) {
      throw classifyAuthFailure(
        AccountManagementException(
          code: json['code'] is String ? json['code'] as String : 'unknown',
          message: json['error'] is String
              ? json['error'] as String
              : 'Password could not be updated.',
          status: response.status,
        ),
      );
    }
    final profile = json['profile'];
    if (profile is! Map) {
      throw AccountManagementException.invalidResponse(status: response.status);
    }
    return SessionProfile.fromJson(Map<String, dynamic>.from(profile));
  }

  Future<BackendVerification> submitVerification({
    required String claimType,
    required String campusId,
    required String unit,
    required String documentName,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    final currentUser = user;
    if (currentUser == null) throw const AuthException('Please sign in again.');
    final path = '${currentUser.id}/current';
    await _client.storage
        .from('verification-documents')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mimeType, upsert: true),
        );
    try {
      final row = await _client
          .from('verification_submissions')
          .upsert({
            'user_id': currentUser.id,
            'claim_type': claimType,
            'campus_id': campusId,
            'unit': unit,
            'document_name': documentName,
            'document_path': path,
            'document_mime_type': mimeType,
            'status': 'pending',
            'reason': null,
            'decided_at': null,
            'decided_by': null,
            'submitted_at': DateTime.now().toUtc().toIso8601String(),
          }, onConflict: 'user_id')
          .select(
            '*, profiles!verification_submissions_user_id_fkey(full_name,email)',
          )
          .single();
      return BackendVerification.fromJson(Map<String, dynamic>.from(row));
    } catch (_) {
      await _client.storage.from('verification-documents').remove([path]);
      rethrow;
    }
  }

  Future<BackendVerification?> currentVerification() async {
    final currentUser = user;
    if (currentUser == null) return null;
    final row = await _client
        .from('verification_submissions')
        .select(
          '*, profiles!verification_submissions_user_id_fkey(full_name,email)',
        )
        .eq('user_id', currentUser.id)
        .maybeSingle();
    if (row == null) return null;
    return BackendVerification.fromJson(Map<String, dynamic>.from(row));
  }

  Future<List<BackendVerification>> verifications() async {
    final rows = await _client
        .from('verification_submissions')
        .select(
          '*, profiles!verification_submissions_user_id_fkey(full_name,email)',
        )
        .order('submitted_at', ascending: false);
    return (rows as List)
        .map(
          (row) => BackendVerification.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList();
  }

  Stream<List<BackendVerification>> verificationStream() => _client
      .from('verification_submissions')
      .stream(primaryKey: ['id'])
      .order('submitted_at', ascending: false)
      .asyncMap((_) => verifications());

  Future<Uint8List> downloadDocument(String path) =>
      _client.storage.from('verification-documents').download(path);

  Future<void> decideVerification({
    required String submissionId,
    required String decision,
    String? reason,
  }) async {
    final trimmedReason = reason?.trim();
    await _client.rpc(
      'decide_verification',
      params: {
        'p_submission_id': submissionId,
        'p_decision': decision,
        'p_reason': trimmedReason == null || trimmedReason.isEmpty
            ? null
            : trimmedReason,
      },
    );
  }

  static String _uuid() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static const _reservationSelect =
      '*,reservation_occurrences(*),reservation_attachments(*),'
      'reservation_events(*),payment_transactions(*),'
      'reservation_price_lines(*),'
      'reservation_terms_acceptances(accepted_at,content_hash,terms_versions(id,title,version,content)),'
      'payment_method:facility_payment_methods!reservation_requests_payment_method_id_fkey(*),'
      'reservation_feedback(*),reservation_permits(*),'
      'reservation_signature_requests(id,status,requested_at,signed_at),'
      'reservation_use_assessments(*,reservation_use_assessment_files(*))';

  @override
  Future<List<BackendReservation>> reservations() async {
    final rows = await _client
        .from('reservation_requests')
        .select(_reservationSelect)
        .order('created_at', ascending: false);
    return (rows as List)
        .map(
          (row) => BackendReservation.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList();
  }

  @override
  Stream<List<BackendReservation>> reservationStream() => _client
      .from('reservation_requests')
      .stream(primaryKey: ['id'])
      .asyncMap((_) => reservations());

  @override
  Future<List<BackendAssistantConversation>> assistantConversations() async {
    final rows = await _client
        .from('assistant_conversations')
        .select()
        .order('last_activity_at', ascending: false)
        .order('id', ascending: false);
    return [
      for (final row in rows as List)
        BackendAssistantConversation.fromJson(
          Map<String, dynamic>.from(row as Map),
        ),
    ];
  }

  @override
  Future<BackendAssistantConversation> createAssistantConversation({
    required String title,
    Map<String, dynamic> activeDraft = const {},
  }) async {
    final currentUser = user;
    if (currentUser == null) throw const AuthException('Please sign in again.');
    final row = await _client
        .from('assistant_conversations')
        .insert({
          'owner_id': currentUser.id,
          'title': title.trim().isEmpty ? 'New chat' : title.trim(),
          'active_draft': activeDraft,
        })
        .select()
        .single();
    return BackendAssistantConversation.fromJson(
      Map<String, dynamic>.from(row),
    );
  }

  @override
  Future<List<BackendAssistantMessage>> assistantMessages(
    String conversationId,
  ) async {
    final rows = await _client
        .from('assistant_messages')
        .select()
        .eq('conversation_id', conversationId)
        .order('created_at')
        .order('id');
    return [
      for (final row in rows as List)
        BackendAssistantMessage.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<void> appendAssistantMessages(
    String conversationId,
    List<BackendAssistantMessage> messages,
  ) async {
    if (messages.isEmpty) return;
    await _client.from('assistant_messages').insert([
      for (final message in messages)
        {
          'conversation_id': conversationId,
          'sender': message.sender,
          'message_type': message.messageType,
          'text': message.text,
          'payload': message.payload,
          'reservation_id': message.reservationId,
          'action': message.action,
          'created_at': message.createdAt.toUtc().toIso8601String(),
        },
    ]);
  }

  @override
  Future<void> updateAssistantConversation(
    String conversationId, {
    String? title,
    Map<String, dynamic>? activeDraft,
  }) async {
    final values = <String, dynamic>{};
    if (title != null) {
      values['title'] = title.trim().isEmpty ? 'New chat' : title.trim();
    }
    if (activeDraft != null) values['active_draft'] = activeDraft;
    if (values.isEmpty) return;
    await _client
        .from('assistant_conversations')
        .update(values)
        .eq('id', conversationId);
  }

  @override
  Future<List<BackendBusyWindow>> facilityBusyWindows({
    required List<String> facilityIds,
    required DateTime from,
    required DateTime to,
  }) async {
    if (facilityIds.isEmpty) return const [];
    final data = await _client.rpc(
      'facility_busy_windows',
      params: {
        'p_facility_ids': facilityIds,
        'p_from': from.toUtc().toIso8601String(),
        'p_to': to.toUtc().toIso8601String(),
      },
    );
    return [
      for (final row in (data as List? ?? const []))
        BackendBusyWindow.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<List<BackendPublicReservationSlot>> publicReservationCalendar({
    required List<String> facilityIds,
    required DateTime from,
    required DateTime to,
  }) async {
    if (facilityIds.isEmpty) return const [];
    late final Object? data;
    try {
      data = await _client.rpc(
        'public_reservation_calendar',
        params: {
          'p_facility_ids': facilityIds,
          'p_from': from.toUtc().toIso8601String(),
          'p_to': to.toUtc().toIso8601String(),
        },
      );
    } on PostgrestException catch (error) {
      if (error.code != 'PGRST202') rethrow;
      final fallback = await facilityBusyWindows(
        facilityIds: facilityIds,
        from: from,
        to: to,
      );
      return [
        for (final row in fallback)
          BackendPublicReservationSlot(
            facilityId: row.facilityId,
            startsAt: row.startsAt,
            endsAt: row.endsAt,
          ),
      ];
    }
    return [
      for (final row in (data as List? ?? const []))
        BackendPublicReservationSlot.fromJson(
          Map<String, dynamic>.from(row as Map),
        ),
    ];
  }

  @override
  Future<BackendReservation> submitReservation(ReservationDraft draft) async {
    final currentUser = user;
    if (currentUser == null) throw const AuthException('Please sign in again.');
    if (draft.pricingFingerprint == null) {
      throw const FormatException(
        'Review the current server quote before submitting.',
      );
    }
    final requestId = _uuid();
    final uploaded = <Map<String, dynamic>>[];
    try {
      for (final file in draft.attachments) {
        final extension = file.name.contains('.')
            ? '.${file.name.split('.').last.toLowerCase()}'
            : '';
        final path = '${currentUser.id}/$requestId/${_uuid()}$extension';
        await _client.storage
            .from('reservation-attachments')
            .uploadBinary(
              path,
              file.bytes,
              fileOptions: FileOptions(contentType: file.mimeType),
            );
        uploaded.add({
          'storage_path': path,
          'file_name': file.name,
          'mime_type': file.mimeType,
          'byte_size': file.bytes.lengthInBytes,
        });
      }
      final details = draft.externalPermitDetails;
      await _client.rpc(
        'submit_reservation_v3',
        params: {
          'p_request_id': requestId,
          'p_facility_id': draft.facilityId,
          'p_purpose': draft.purpose,
          'p_headcount': draft.headcount,
          'p_starts_at': [
            for (final date in draft.startsAt) date.toUtc().toIso8601String(),
          ],
          'p_ends_at': [
            for (final date in draft.endsAt) date.toUtc().toIso8601String(),
          ],
          'p_amenity_ids': draft.amenityIds,
          'p_requested_amenities': draft.requestedAmenities,
          'p_terms_version_ids': draft.termsVersionIds,
          'p_pricing_fingerprint': draft.pricingFingerprint,
          'p_attachment_metadata': uploaded,
          'p_discount_claim_id': draft.discountClaimId,
          'p_external_company_organization': details?.companyOrOrganization,
          'p_external_complete_address': details?.completeAddress,
          'p_external_contact_numbers': details?.contactNumbers,
          'p_external_admission_fee_centavos': details?.admissionFeeCentavos,
          'p_item_quantities': draft.permitItemQuantities,
        },
      );
      final row = await _client
          .from('reservation_requests')
          .select(_reservationSelect)
          .eq('id', requestId)
          .single();
      return BackendReservation.fromJson(Map<String, dynamic>.from(row));
    } catch (_) {
      if (uploaded.isNotEmpty) {
        await _client.storage.from('reservation-attachments').remove([
          for (final item in uploaded) item['storage_path'] as String,
        ]);
      }
      rethrow;
    }
  }

  @override
  Future<BackendReservationQuote> reservationQuote({
    required String facilityId,
    required List<DateTime> startsAt,
    required List<DateTime> endsAt,
    required int headcount,
    List<String> amenityIds = const [],
    String? discountClaimId,
  }) async {
    final data = await _client.rpc(
      'get_reservation_quote',
      params: {
        'p_facility_id': facilityId,
        'p_starts_at': [
          for (final value in startsAt) value.toUtc().toIso8601String(),
        ],
        'p_ends_at': [
          for (final value in endsAt) value.toUtc().toIso8601String(),
        ],
        'p_amenity_ids': amenityIds,
        'p_headcount': headcount,
        'p_discount_claim_id': discountClaimId,
      },
    );
    final quote = BackendReservationQuote.fromJson(
      Map<String, dynamic>.from(data as Map),
    );
    if (quote.adminLane != 'internal') return quote;
    return BackendReservationQuote(
      facilityId: quote.facilityId,
      audience: quote.audience,
      adminLane: quote.adminLane,
      facilityAmountCentavos: 0,
      amenityAmountCentavos: 0,
      discountAmountCentavos: 0,
      totalAmountCentavos: 0,
      requiredDownPaymentCentavos: 0,
      pricingFingerprint: quote.pricingFingerprint,
      lines: [
        for (final line in quote.lines)
          BackendPriceLine(
            type: line.type,
            sourceId: line.sourceId,
            label: line.label,
            quantity: line.quantity,
            unitAmountCentavos: 0,
            lineTotalCentavos: 0,
          ),
      ],
      terms: quote.terms,
      downPaymentPercent: quote.downPaymentPercent,
      paymentExemption: 'internal_user',
    );
  }

  PaymentTransaction _paymentFromJson(Map<String, dynamic> json) =>
      PaymentTransaction(
        id: '${json['id']}',
        requestId: '${json['request_id']}',
        payerId: '${json['payer_id']}',
        purpose: PaymentPurpose.fromRaw('${json['purpose']}'),
        amountCentavos: (json['amount_centavos'] as num?)?.toInt() ?? 0,
        referenceNumber: '${json['reference_number'] ?? ''}',
        proofPath: '${json['proof_path'] ?? ''}',
        status: PaymentDecisionStatus.fromRaw('${json['status']}'),
        submittedAt: DateTime.parse('${json['submitted_at']}'),
        verifiedBy: json['verified_by'] as String?,
        verifiedAt: _date(json['verified_at']),
        rejectionReason: json['rejection_reason'] as String?,
        correctionDueAt: _date(json['correction_due_at']),
        correctionCount: (json['correction_count'] as num?)?.toInt() ?? 0,
        lastCorrectedAt: _date(json['last_corrected_at']),
      );

  @override
  Future<PaymentSummary> paymentSummary(String requestId) async {
    final data = await _client.rpc(
      'reservation_payment_summary',
      params: {'p_request_id': requestId},
    );
    final json = Map<String, dynamic>.from(data as Map);
    return PaymentSummary(
      status: AggregatePaymentStatus.fromRaw('${json['status']}'),
      totalAmountCentavos:
          (json['total_amount_centavos'] as num?)?.toInt() ?? 0,
      requiredDownPaymentCentavos:
          (json['required_down_payment_centavos'] as num?)?.toInt() ?? 0,
      verifiedAmountCentavos:
          (json['verified_amount_centavos'] as num?)?.toInt() ?? 0,
      submittedAmountCentavos:
          (json['submitted_amount_centavos'] as num?)?.toInt() ?? 0,
      outstandingAmountCentavos:
          (json['outstanding_amount_centavos'] as num?)?.toInt() ?? 0,
      paymentDueAt: _date(json['payment_due_at']),
      balanceDueAt: _date(json['balance_due_at']),
      downPaymentPercent: (json['down_payment_percent'] as num?)?.toInt() ?? 50,
      paymentExemption: '${json['payment_exemption'] ?? 'none'}',
      correctionAmountCentavos:
          (json['correction_amount_centavos'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<List<PaymentTransaction>> payments(String requestId) async {
    final rows = await _client
        .from('payment_transactions')
        .select()
        .eq('request_id', requestId)
        .order('submitted_at', ascending: false);
    return [
      for (final row in rows as List)
        _paymentFromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<PaymentTransaction> submitPayment(PaymentSubmissionDraft draft) async {
    final currentUser = user;
    if (currentUser == null) throw const AuthException('Please sign in again.');
    final transactionId = _uuid();
    final extension = draft.proof.name.contains('.')
        ? '.${draft.proof.name.split('.').last.toLowerCase()}'
        : '';
    final path =
        '${currentUser.id}/${draft.requestId}/$transactionId$extension';
    try {
      await _client.storage
          .from('payment-proofs')
          .uploadBinary(
            path,
            draft.proof.bytes,
            fileOptions: FileOptions(contentType: draft.proof.mimeType),
          )
          .timeout(const Duration(seconds: 90));
      final data = await _client
          .rpc(
            'submit_payment',
            params: {
              'p_transaction_id': transactionId,
              'p_request_id': draft.requestId,
              'p_purpose': draft.purpose.raw,
              'p_amount_centavos': draft.amountCentavos,
              'p_reference_number': draft.referenceNumber,
              'p_proof_path': path,
              'p_idempotency_key': _uuid(),
            },
          )
          .timeout(const Duration(seconds: 30));
      return _paymentFromJson(Map<String, dynamic>.from(data as Map));
    } catch (_) {
      try {
        await _client.storage.from('payment-proofs').remove([path]);
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<PaymentTransaction> decidePayment({
    required String paymentId,
    required String decision,
    String? reason,
  }) async {
    final data = await _client.rpc(
      'decide_payment',
      params: {
        'p_payment_id': paymentId,
        'p_decision': decision,
        'p_reason': reason,
      },
    );
    return _paymentFromJson(Map<String, dynamic>.from(data as Map));
  }

  @override
  Future<String> paymentProofUrl(String path) =>
      _client.storage.from('payment-proofs').createSignedUrl(path, 60 * 10);

  @override
  Future<void> submitReservationUseAssessment({
    required String requestId,
    required String occurrenceId,
    required int cleanlinessRating,
    required int equipmentConditionRating,
    required bool leftUnclean,
    required bool equipmentDamaged,
    required String comment,
    List<ReservationUpload> evidence = const [],
  }) async {
    final uploaded = <String>[];
    final metadata = <Map<String, dynamic>>[];
    try {
      for (final file in evidence.take(3)) {
        final extension = file.mimeType == 'image/png' ? '.png' : '.jpg';
        final path = '$requestId/$occurrenceId/${_uuid()}$extension';
        await _client.storage
            .from('facility-assessment-evidence')
            .uploadBinary(
              path,
              file.bytes,
              fileOptions: FileOptions(contentType: file.mimeType),
            );
        uploaded.add(path);
        metadata.add({
          'storage_path': path,
          'file_name': file.name,
          'mime_type': file.mimeType,
          'byte_size': file.bytes.lengthInBytes,
        });
      }
      await _client.rpc(
        'submit_reservation_use_assessment',
        params: {
          'p_occurrence_id': occurrenceId,
          'p_cleanliness_rating': cleanlinessRating,
          'p_equipment_condition_rating': equipmentConditionRating,
          'p_left_unclean': leftUnclean,
          'p_equipment_damaged': equipmentDamaged,
          'p_comment': comment.trim(),
          'p_attachment_metadata': metadata,
          'p_idempotency_key': _uuid(),
        },
      );
    } catch (_) {
      if (uploaded.isNotEmpty) {
        try {
          await _client.storage
              .from('facility-assessment-evidence')
              .remove(uploaded);
        } catch (_) {}
      }
      rethrow;
    }
  }

  @override
  Future<ReservationPermit?> ensurePermit(String requestId) async {
    final response = await _client.functions.invoke(
      'generate-permit',
      body: {'action': 'ensure', 'requestId': requestId},
    );
    if (response.data is! Map) {
      throw StateError('Permit generator returned an invalid response.');
    }
    final data = Map<String, dynamic>.from(response.data as Map);
    if (data['error'] is String) throw StateError('${data['error']}');
    final permit = data['permit'];
    return permit is Map
        ? ReservationPermit.fromJson(Map<String, dynamic>.from(permit))
        : null;
  }

  @override
  Future<PermitReadiness> permitReadiness(String requestId) async {
    final data = await _client.rpc(
      'get_reservation_permit_readiness',
      params: {'p_request_id': requestId},
    );
    return PermitReadiness.fromJson(Map<String, dynamic>.from(data as Map));
  }

  @override
  Future<Uint8List> downloadPermitPdf(String path) =>
      _client.storage.from('reservation-permits').download(path);

  @override
  Future<Uint8List> previewPermit(String requestId) async {
    final response = await _client.functions.invoke(
      'generate-permit',
      body: {'action': 'preview', 'requestId': requestId},
    );
    if (response.data is Uint8List) return response.data as Uint8List;
    if (response.data is List<int>) {
      return Uint8List.fromList(response.data as List<int>);
    }
    if (response.data is Map && (response.data as Map)['error'] != null) {
      throw StateError('${(response.data as Map)['error']}');
    }
    throw StateError('Permit preview service returned an invalid response.');
  }

  @override
  Future<void> requestReservationSignature(String requestId) => _client.rpc(
    'request_reservation_signature',
    params: {'p_request_id': requestId},
  );

  @override
  Future<void> submitReservationSignature({
    required String signatureRequestId,
    required String requestId,
    required ReservationUpload signature,
  }) async {
    final currentUser = user;
    if (currentUser == null) throw const AuthException('Please sign in again.');
    final path = '${currentUser.id}/$requestId/${_uuid()}-${signature.name}';
    await _client.storage
        .from('reservation-signatures')
        .uploadBinary(
          path,
          signature.bytes,
          fileOptions: FileOptions(contentType: signature.mimeType),
        );
    try {
      await _client.rpc(
        'submit_reservation_signature',
        params: {
          'p_signature_request_id': signatureRequestId,
          'p_storage_path': path,
          'p_file_name': signature.name,
          'p_mime_type': signature.mimeType,
          'p_byte_size': signature.bytes.lengthInBytes,
          'p_sha256': sha256.convert(signature.bytes).toString(),
        },
      );
    } catch (_) {
      await _client.storage.from('reservation-signatures').remove([path]);
      rethrow;
    }
  }

  @override
  Future<void> updateExternalPermitDetails(
    String requestId,
    ExternalPermitDetails details,
  ) => _client.rpc(
    'update_external_permit_details',
    params: {
      'p_request_id': requestId,
      'p_company_organization': details.companyOrOrganization,
      'p_complete_address': details.completeAddress,
      'p_contact_numbers': details.contactNumbers,
      'p_admission_fee_centavos': details.admissionFeeCentavos,
    },
  );

  @override
  Future<void> uploadOfficialSignature(
    OfficialSignatureSlot slot,
    ReservationUpload signature,
  ) async {
    await _signatureFunction('upload', {
      'slot': slot.raw,
      'fileName': signature.name,
      'mimeType': signature.mimeType,
      'bytesBase64': base64Encode(signature.bytes),
    });
  }

  @override
  Future<Map<String, dynamic>> previewOfficialSignature(
    OfficialSignatureSlot slot,
  ) => _signatureFunction('preview', {'slot': slot.raw});

  Future<Map<String, dynamic>> _signatureFunction(
    String action,
    Map<String, dynamic> values,
  ) async {
    final response = await _client.functions.invoke(
      'permit-signatures',
      body: {'action': action, ...values},
    );
    if (response.data is! Map) {
      throw StateError(
        'Permit signature service returned an invalid response.',
      );
    }
    final data = Map<String, dynamic>.from(response.data as Map);
    if (data['error'] is String) throw StateError('${data['error']}');
    return data;
  }

  @override
  Future<Map<String, dynamic>> verifyPermit(String token) async {
    final data = await _client.rpc('verify_permit', params: {'p_token': token});
    return Map<String, dynamic>.from(data as Map);
  }

  @override
  Future<void> saveFacilityConfiguration(
    FacilityConfigurationDraft draft,
  ) async {
    await _client.rpc(
      'save_facility_configuration_v3',
      params: {
        'p_facility_id': draft.facilityId,
        'p_rates': [
          for (final entry in draft.rates.entries)
            {'audience': entry.key, 'hourly_rate_centavos': entry.value},
        ],
        'p_amenities': [
          for (final amenity in draft.amenities)
            {
              'name': amenity.name,
              'description': amenity.description,
              'price_centavos': amenity.priceCentavos,
              'pricing_unit': amenity.pricingUnit,
              'internal_permit_row_code': amenity.internalPermitRowCode,
              'external_permit_row_code': amenity.externalPermitRowCode,
              'permit_quantity_required': amenity.permitQuantityRequired,
            },
        ],
        'p_account_name': draft.accountName,
        'p_account_number': draft.accountNumber,
        'p_instructions': draft.instructions,
        'p_deposit_window_minutes': draft.depositWindowMinutes,
        'p_balance_due_lead_minutes': draft.balanceDueLeadMinutes,
        'p_correction_window_minutes': draft.correctionWindowMinutes,
        'p_down_payment_percent': draft.downPaymentPercent,
        'p_internal_permit_row_code': draft.internalPermitRowCode,
        'p_external_permit_row_code': draft.externalPermitRowCode,
      },
    );
  }

  @override
  Future<List<AuditEntry>> facilityActivity(String facilityId) async {
    final rows = await _client
        .from('audit_entries')
        .select()
        .eq('entity_type', 'facility')
        .eq('entity_id', facilityId)
        .order('created_at', ascending: false)
        .limit(100);
    return [
      for (final row in rows as List)
        AuditEntry.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<BackendFeedback> submitFeedback({
    required String reservationId,
    required int rating,
    String comment = '',
    int? cleanliness,
    int? condition,
    int? equipment,
  }) async {
    final row = await _client.rpc(
      'submit_reservation_feedback',
      params: {
        'p_reservation_id': reservationId,
        'p_rating': rating,
        'p_comment': comment,
        'p_cleanliness': cleanliness,
        'p_condition': condition,
        'p_equipment': equipment,
      },
    );
    return BackendFeedback.fromJson(Map<String, dynamic>.from(row as Map));
  }

  @override
  Future<BackendFeedbackPage> feedbackEntries(FeedbackQuery query) async {
    final data = await _client.rpc(
      'feedback_admin_list',
      params: {
        'p_search': query.search.isEmpty ? null : query.search,
        'p_facility_id': query.facilityId,
        'p_min_rating': query.minRating,
        'p_max_rating': query.maxRating,
        'p_from': query.from?.toUtc().toIso8601String(),
        'p_to': query.to?.toUtc().toIso8601String(),
        'p_sort': query.sortParam,
        'p_limit': query.limit,
        'p_offset': query.offset,
        'p_sentiment': query.sentiment?.value,
        'p_topic': query.topic?.value,
        'p_analysis_status': query.analysisStatus?.value,
        'p_needs_review': query.needsReview,
      },
    );
    return BackendFeedbackPage.fromJson(Map<String, dynamic>.from(data as Map));
  }

  @override
  Future<BackendFeedbackSummary> feedbackSummary(FeedbackQuery query) async {
    final data = await _client.rpc(
      'feedback_admin_summary',
      params: {
        'p_facility_id': query.facilityId,
        'p_from': query.from?.toUtc().toIso8601String(),
        'p_to': query.to?.toUtc().toIso8601String(),
      },
    );
    return BackendFeedbackSummary.fromJson(
      Map<String, dynamic>.from(data as Map),
    );
  }

  @override
  Future<BackendFeedbackSentimentAnalytics> feedbackSentimentAnalytics(
    FeedbackQuery query,
  ) async {
    final data = await _client.rpc(
      'feedback_sentiment_analytics',
      params: {
        'p_search': query.search.isEmpty ? null : query.search,
        'p_facility_id': query.facilityId,
        'p_min_rating': query.minRating,
        'p_max_rating': query.maxRating,
        'p_from': query.from?.toUtc().toIso8601String(),
        'p_to': query.to?.toUtc().toIso8601String(),
        'p_sentiment': query.sentiment?.value,
        'p_topic': query.topic?.value,
        'p_analysis_status': query.analysisStatus?.value,
        'p_needs_review': query.needsReview,
      },
    );
    return BackendFeedbackSentimentAnalytics.fromJson(
      Map<String, dynamic>.from(data as Map),
    );
  }

  @override
  Future<BackendFeedbackSentimentAnalysis?> retryFeedbackSentiment(
    String feedbackId,
  ) async {
    final data = await _client.rpc(
      'feedback_sentiment_retry',
      params: {'p_feedback_id': feedbackId, 'p_version': 1},
    );
    if (data is! Map) return null;
    return BackendFeedbackSentimentAnalysis.fromJson(
      Map<String, dynamic>.from(data),
    );
  }

  @override
  Stream<void> feedbackSentimentAnalysisStream() => _client
      .from('feedback_sentiment_analyses')
      .stream(primaryKey: ['id'])
      .map<void>((_) {});

  @override
  Future<BackendLoyaltySummary> loyaltySummary() async {
    final data = await _client.rpc('loyalty_my_summary');
    return BackendLoyaltySummary.fromJson(
      Map<String, dynamic>.from(data as Map),
    );
  }

  @override
  Stream<List<BackendLoyaltyTransaction>> loyaltyTransactionStream() {
    final userId = user?.id;
    var stream = _client
        .from('loyalty_transactions')
        .stream(primaryKey: ['id']);
    if (userId != null) {
      stream = stream.eq('user_id', userId);
    }
    return stream.asyncMap((rows) async {
      final summary = await loyaltySummary();
      return summary.transactions;
    });
  }

  @override
  Future<BackendLoyaltyRedemption> redeemLoyaltyReward(String rewardId) async {
    final row = await _client.rpc(
      'redeem_loyalty_reward',
      params: {'p_reward_id': rewardId},
    );
    return BackendLoyaltyRedemption.fromJson(
      Map<String, dynamic>.from(row as Map),
    );
  }

  @override
  Future<PaymentTransaction> correctPaymentSubmission({
    required PaymentTransaction payment,
    required int amountCentavos,
    required String referenceNumber,
    required ReservationUpload proof,
  }) async {
    final currentUser = user;
    if (currentUser == null) throw const AuthException('Please sign in again.');
    final replacementId = _uuid();
    final extension = proof.name.contains('.')
        ? '.${proof.name.split('.').last.toLowerCase()}'
        : '';
    final path =
        '${currentUser.id}/${payment.requestId}/$replacementId$extension';
    try {
      await _client.storage
          .from('payment-proofs')
          .uploadBinary(
            path,
            proof.bytes,
            fileOptions: FileOptions(contentType: proof.mimeType),
          )
          .timeout(const Duration(seconds: 90));
      final data = await _client
          .rpc(
            'correct_payment_submission',
            params: {
              'p_payment_id': payment.id,
              'p_amount_centavos': amountCentavos,
              'p_reference_number': referenceNumber,
              'p_proof_path': path,
              'p_idempotency_key': _uuid(),
            },
          )
          .timeout(const Duration(seconds: 30));
      return _paymentFromJson(Map<String, dynamic>.from(data as Map));
    } catch (_) {
      try {
        await _client.storage.from('payment-proofs').remove([path]);
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<BackendLoyaltyDiscountClaim> claimLoyaltyDiscount(
    String offerId,
  ) async {
    final row = await _client.rpc(
      'claim_loyalty_discount',
      params: {'p_offer_id': offerId},
    );
    return BackendLoyaltyDiscountClaim.fromJson(
      Map<String, dynamic>.from(row as Map),
    );
  }

  @override
  Future<List<BackendLoyaltyBalanceRow>> loyaltyBalances({
    String search = '',
    int limit = 100,
  }) async {
    final rows = await _client.rpc(
      'loyalty_admin_balances',
      params: {'p_search': search.isEmpty ? null : search, 'p_limit': limit},
    );
    return [
      for (final row in rows as List)
        BackendLoyaltyBalanceRow.fromJson(
          Map<String, dynamic>.from(row as Map),
        ),
    ];
  }

  @override
  Future<List<BackendLoyaltyTransaction>> loyaltyLedger(
    String userId, {
    int limit = 100,
  }) async {
    final rows = await _client.rpc(
      'loyalty_admin_ledger',
      params: {'p_user_id': userId, 'p_limit': limit},
    );
    return [
      for (final row in rows as List)
        BackendLoyaltyTransaction.fromJson(
          Map<String, dynamic>.from(row as Map),
        ),
    ];
  }

  @override
  Future<List<BackendLoyaltyRedemption>> loyaltyRedemptions({
    String? userId,
    int limit = 100,
  }) async {
    final rows = await _client.rpc(
      'loyalty_admin_redemptions',
      params: {'p_user_id': userId, 'p_limit': limit},
    );
    return [
      for (final row in rows as List)
        BackendLoyaltyRedemption.fromJson(
          Map<String, dynamic>.from(row as Map),
        ),
    ];
  }

  @override
  Future<List<BackendLoyaltyAdminClaim>> loyaltyAdminClaims({
    String search = '',
    String? status,
    int limit = 100,
  }) async {
    final rows = await _client.rpc(
      'loyalty_admin_claims',
      params: {
        'p_search': search.isEmpty ? null : search,
        'p_status': status,
        'p_limit': limit,
      },
    );
    return [
      for (final row in rows as List)
        BackendLoyaltyAdminClaim.fromJson(
          Map<String, dynamic>.from(row as Map),
        ),
    ];
  }

  @override
  Future<List<BackendLoyaltyDiscountOffer>> loyaltyDiscountOffers() async {
    final rows = await _client.rpc('loyalty_discount_offer_admin_list');
    return [
      for (final row in rows as List)
        BackendLoyaltyDiscountOffer.fromJson(
          Map<String, dynamic>.from(row as Map),
        ),
    ];
  }

  @override
  Future<BackendLoyaltyDiscountOffer> saveLoyaltyDiscountOffer({
    String? id,
    required String name,
    String description = '',
    required double requiredPoints,
    required DiscountKind discountKind,
    int? fixedAmountCentavos,
    double? percentage,
    String? facilityId,
    required DateTime validFrom,
    required DateTime validUntil,
    bool active = true,
  }) async {
    final row = await _client.rpc(
      'save_loyalty_discount_offer',
      params: {
        'p_id': id,
        'p_name': name,
        'p_description': description,
        'p_required_points': requiredPoints,
        'p_discount_kind': discountKind.raw,
        'p_fixed_amount_centavos': fixedAmountCentavos,
        'p_percentage': percentage,
        'p_facility_id': facilityId,
        'p_valid_from': _dateOnly(validFrom),
        'p_valid_until': _dateOnly(validUntil),
        'p_active': active,
      },
    );
    return BackendLoyaltyDiscountOffer.fromJson(
      Map<String, dynamic>.from(row as Map),
    );
  }

  @override
  Future<void> setLoyaltyDiscountOfferActive(String offerId, bool active) =>
      _client.rpc(
        'set_loyalty_discount_offer_active',
        params: {'p_offer_id': offerId, 'p_active': active},
      );

  @override
  Future<BackendLoyaltyTransaction> adjustLoyaltyPoints({
    required String userId,
    required double points,
    required String reason,
  }) async {
    final row = await _client.rpc(
      'adjust_loyalty_points',
      params: {'p_user_id': userId, 'p_points': points, 'p_reason': reason},
    );
    return BackendLoyaltyTransaction.fromJson(
      Map<String, dynamic>.from(row as Map),
    );
  }

  @override
  Future<ReservationActionResult> performReservationAction(
    ReservationActionCommand command,
  ) async {
    if (command.action == 'self_check_in') {
      final response = await _client.rpc(
        'self_check_in_occurrence',
        params: {
          'p_request_id': command.requestId,
          'p_occurrence_id': command.payload['occurrence_id'],
          'p_expected_version': command.expectedVersion,
          'p_idempotency_key': command.idempotencyKey ?? _uuid(),
        },
      );
      final data = Map<String, dynamic>.from(response as Map);
      return ReservationActionResult(actionId: data['action_id'] as String?);
    }
    if (command.action == 'approve_bump') {
      final response = await _client.rpc(
        'approve_and_bump_reservation',
        params: {
          'p_request_id': command.requestId,
          'p_reason': command.reason,
          'p_expected_version': command.expectedVersion,
          'p_idempotency_key': command.idempotencyKey ?? _uuid(),
        },
      );
      final data = Map<String, dynamic>.from(response as Map);
      return ReservationActionResult(
        actionId: data['action_id'] as String?,
        undoUntil: _date(data['undo_until']),
      );
    }
    if (command.action == 'resubmit') {
      final response = await _client.rpc(
        'resubmit_reservation',
        params: {
          'p_request_id': command.requestId,
          'p_purpose': command.payload['purpose'],
          'p_headcount': command.payload['headcount'],
          'p_occurrence_id': command.payload['occurrence_id'],
          'p_starts_at': command.payload['starts_at'],
          'p_ends_at': command.payload['ends_at'],
          'p_expected_version': command.expectedVersion,
          'p_idempotency_key': command.idempotencyKey ?? _uuid(),
        },
      );
      final data = Map<String, dynamic>.from(response as Map);
      return ReservationActionResult(
        actionId: data['action_id'] as String?,
        undoUntil: _date(data['undo_until']),
      );
    }
    final response = await _client.rpc(
      'reservation_action',
      params: {
        'p_request_id': command.requestId,
        'p_action': command.action,
        'p_reason': command.reason,
        'p_payload': command.payload,
        'p_expected_version': command.expectedVersion,
        'p_idempotency_key': command.idempotencyKey ?? _uuid(),
      },
    );
    final data = Map<String, dynamic>.from(response as Map);
    return ReservationActionResult(
      actionId: data['action_id'] as String?,
      undoUntil: _date(data['undo_until']),
    );
  }

  @override
  Future<ReservationActionResult> bulkApproveReservations(
    List<BackendReservation> reservations,
  ) async {
    final response = await _client.rpc(
      'bulk_approve_reservations',
      params: {
        'p_request_ids': [for (final row in reservations) row.id],
        'p_expected_versions': {
          for (final row in reservations) row.id: row.version,
        },
        'p_idempotency_key': _uuid(),
      },
    );
    final data = Map<String, dynamic>.from(response as Map);
    final actionIds = (data['action_ids'] as List?)?.cast<String>();
    return ReservationActionResult(
      actionId: actionIds == null || actionIds.isEmpty ? null : actionIds.last,
      actionIds: actionIds ?? const [],
    );
  }

  @override
  Future<void> undoReservationAction(String actionId) =>
      _client.rpc('undo_reservation_action', params: {'p_action_id': actionId});

  @override
  Future<String> reservationAttachmentUrl(String path) => _client.storage
      .from('reservation-attachments')
      .createSignedUrl(path, 60 * 10);

  @override
  Future<List<BackendNotification>> notifications() async {
    await _client.rpc('generate_my_reservation_reminders');
    final rows = await _client
        .from('app_notifications')
        .select()
        .order('created_at', ascending: false)
        .limit(100);
    return (rows as List)
        .map(
          (row) => BackendNotification.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList();
  }

  @override
  Stream<List<BackendNotification>> notificationStream() => _client
      .from('app_notifications')
      .stream(primaryKey: ['id'])
      .order('created_at', ascending: false)
      .asyncMap((_) => notifications());

  @override
  Future<void> markNotificationRead(String notificationId) async {
    await _client.rpc(
      'mark_my_notification_read',
      params: {'p_notification_id': notificationId},
    );
  }

  @override
  Future<AnomalyPage> anomalyCenter({
    required AnomalyFilters filters,
    Map<String, dynamic>? cursor,
    int limit = 50,
  }) async {
    final data = await _client.rpc(
      'get_anomaly_center',
      params: {
        'p_filters': filters.toJson(),
        'p_cursor': cursor,
        'p_limit': limit,
      },
    );
    return AnomalyPage.fromJson(Map<String, dynamic>.from(data as Map));
  }

  @override
  Future<AnomalyDetail> anomalyDetail(String anomalyId) async {
    final data = await _client.rpc(
      'get_anomaly_detail',
      params: {'p_anomaly_id': anomalyId},
    );
    return AnomalyDetail.fromJson(Map<String, dynamic>.from(data as Map));
  }

  @override
  Future<AnomalyDetail> transitionReservationAnomaly({
    required String anomalyId,
    required String action,
    String? reasonCode,
    String? note,
  }) async {
    final data = await _client.rpc(
      'transition_reservation_anomaly',
      params: {
        'p_anomaly_id': anomalyId,
        'p_action': action,
        'p_reason_code': reasonCode,
        'p_note': note,
        'p_idempotency_key': _uuid(),
      },
    );
    return AnomalyDetail.fromJson(Map<String, dynamic>.from(data as Map));
  }

  @override
  Future<RenterRiskSummary> reservationRiskSummary(String requestId) async {
    final data = await _client.rpc(
      'get_reservation_risk_summary',
      params: {'p_request_id': requestId},
    );
    return RenterRiskSummary.fromJson(Map<String, dynamic>.from(data as Map));
  }

  @override
  Future<RenterRiskSummary> evaluateReservationRiskNow(String requestId) async {
    final data = await _client.rpc(
      'evaluate_reservation_risk_now',
      params: {'p_request_id': requestId},
    );
    return RenterRiskSummary.fromJson(Map<String, dynamic>.from(data as Map));
  }

  @override
  Future<void> correctOccurrenceAttendance({
    required String occurrenceId,
    required String targetStage,
    required String reason,
  }) async {
    await _client.rpc(
      'correct_occurrence_attendance',
      params: {
        'p_occurrence_id': occurrenceId,
        'p_target_stage': targetStage,
        'p_reason': reason,
        'p_idempotency_key': _uuid(),
      },
    );
  }

  @override
  Future<List<Map<String, dynamic>>> checkMyReservationOverlaps({
    required List<DateTime> startsAt,
    required List<DateTime> endsAt,
    String? excludeRequestId,
  }) async {
    final data = await _client.rpc(
      'check_my_reservation_overlaps',
      params: {
        'p_starts_at': [
          for (final value in startsAt) value.toUtc().toIso8601String(),
        ],
        'p_ends_at': [
          for (final value in endsAt) value.toUtc().toIso8601String(),
        ],
        'p_exclude_request_id': excludeRequestId,
      },
    );
    final json = Map<String, dynamic>.from(data as Map);
    return [
      for (final raw in (json['overlaps'] as List? ?? const []))
        Map<String, dynamic>.from(raw as Map),
    ];
  }

  @override
  Future<Map<String, bool>> notificationPreferences() async {
    final currentUser = user;
    if (currentUser == null) return const {};
    final row = await _client
        .from('notification_preferences')
        .select()
        .eq('user_id', currentUser.id)
        .maybeSingle();
    return {
      'Decision on my requests': row?['reservation_decisions'] as bool? ?? true,
      'Reminder the day before': row?['day_before_reminders'] as bool? ?? true,
      'New facilities on campus': row?['new_facilities'] as bool? ?? false,
    };
  }

  @override
  Future<void> saveNotificationPreferences(
    Map<String, bool> preferences,
  ) async {
    final currentUser = user;
    if (currentUser == null) throw const AuthException('Please sign in again.');
    await _client.from('notification_preferences').upsert({
      'user_id': currentUser.id,
      'reservation_decisions': preferences['Decision on my requests'] ?? true,
      'day_before_reminders': preferences['Reminder the day before'] ?? true,
      'new_facilities': preferences['New facilities on campus'] ?? false,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  String facilityPhotoUrl(String path) =>
      _client.storage.from('facility-photos').getPublicUrl(path);

  @override
  Future<List<BackendFacility>> facilities() async {
    final rows = await _client
        .from('facilities')
        .select(
          '*,facility_amenities(*),facility_payment_methods(*),facility_rates(*),'
          'facility_rating_stats(*)',
        )
        .isFilter('archived_at', null)
        .order('updated_at', ascending: false);
    final accessRows = await _client.rpc('my_facility_access');
    final access = <String, Map<String, dynamic>>{
      for (final row in (accessRows as List? ?? const []))
        '${(row as Map)['facility_id']}': Map<String, dynamic>.from(row),
    };
    return [
      for (final raw in rows as List)
        BackendFacility.fromJson(
          Map<String, dynamic>.from(raw as Map),
        ).withAccess(access['${raw['id']}']),
    ];
  }

  @override
  Stream<List<BackendFacility>> facilityStream() => _client
      .from('facilities')
      .stream(primaryKey: ['id'])
      .asyncMap((_) => facilities());

  @override
  Future<BackendFacility> saveFacility(
    FacilityDraft draft, {
    String? editingId,
  }) async {
    final currentUser = user;
    if (currentUser == null) throw const AuthException('Please sign in again.');

    var previousPaths = <String>[];
    if (editingId != null) {
      final existing = await _client
          .from('facilities')
          .select('photo_paths')
          .eq('id', editingId)
          .single();
      previousPaths = ((existing['photo_paths'] as List?) ?? const [])
          .map((value) => '$value')
          .toList();
    }

    final resolved = await _resolveFacilityPhotos(draft.photos, currentUser.id);
    try {
      final payload = _facilityPayload(draft, resolved.paths);
      final dynamic row;
      if (editingId == null) {
        row = await _client
            .from('facilities')
            .insert(payload)
            .select()
            .single();
      } else {
        row = await _client
            .from('facilities')
            .update(payload)
            .eq('id', editingId)
            .select()
            .single();
      }

      final removed = previousPaths
          .where((path) => !resolved.paths.contains(path))
          .toList();
      if (removed.isNotEmpty) {
        try {
          await _client.storage.from('facility-photos').remove(removed);
        } catch (_) {}
      }
      final savedId = '${(row as Map)['id']}';
      final refreshed = await facilities();
      return refreshed.firstWhere((facility) => facility.id == savedId);
    } catch (_) {
      if (resolved.uploaded.isNotEmpty) {
        try {
          await _client.storage
              .from('facility-photos')
              .remove(resolved.uploaded);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Map<String, dynamic> _facilityPayload(
    FacilityDraft draft,
    List<String> photoPaths,
  ) {
    final outside =
        draft.pin != null &&
        (draft.confirmedOutside || !inPolygon(draft.pin!, campus.boundary));
    final status = outside
        ? 'under_review'
        : switch (draft.status) {
            FacilityStatus.active => 'active',
            FacilityStatus.maintenance => 'maintenance',
            FacilityStatus.draft => 'draft',
          };
    final confidence = draft.pin == null
        ? 'none'
        : (outside ? 'needs_check' : 'verified');
    return {
      'name': draft.name.trim(),
      'room': draft.room.trim(),
      'building': draft.building,
      'category': draft.category,
      'capacity': draft.capacitySeats,
      'status': status,
      'pin_confidence': confidence,
      'campus_name': draft.campusName,
      'floor': draft.floor,
      'latitude': draft.pin?.latitude,
      'longitude': draft.pin?.longitude,
      'accuracy': draft.accuracy,
      'confirmed_outside': draft.confirmedOutside,
      'description': draft.description.trim(),
      'geo_building': draft.geoBuilding,
      'street': draft.street,
      'barangay': draft.barangay,
      'municipality': draft.municipality,
      'province': draft.province,
      'region': draft.region,
      'country': draft.country,
      'geo_edited': draft.geoEdited.toList(),
      'amenities': List<String>.from(draft.amenities),
      'photo_paths': photoPaths,
      'requires_approval': draft.requiresApproval,
      'public_listing': draft.publicListing,
      'open_days': List<bool>.from(draft.days),
      'open_time': draft.openTime,
      'close_time': draft.closeTime,
      'max_duration': draft.maxDuration,
      'advance_booking': draft.advance,
      'booking_buffer': draft.buffer,
      'max_duration_minutes':
          (int.tryParse(
                RegExp(r'\d+').firstMatch(draft.maxDuration)?.group(0) ?? '',
              ) ??
              4) *
          60,
      'advance_booking_days':
          int.tryParse(
            RegExp(r'\d+').firstMatch(draft.advance)?.group(0) ?? '',
          ) ??
          30,
      'booking_buffer_minutes':
          int.tryParse(
            RegExp(r'\d+').firstMatch(draft.buffer)?.group(0) ?? '',
          ) ??
          15,
      'facility_classification': 'shared',
      'archived_at': null,
    };
  }

  Future<({List<String> paths, List<String> uploaded})> _resolveFacilityPhotos(
    List<FacilityPhoto> photos,
    String userId,
  ) async {
    if (photos.isEmpty) {
      throw const FormatException('Add at least one facility photo.');
    }
    if (photos.length > 8) {
      throw const FormatException('A facility can have at most 8 photos.');
    }

    final paths = <String>[];
    final uploaded = <String>[];
    try {
      for (var index = 0; index < photos.length; index++) {
        final photo = photos[index];
        if (photo.storagePath case final existing?) {
          paths.add(existing);
          continue;
        }
        if (photo.isPlaceholder) {
          throw const FormatException(
            'Placeholder images cannot be saved. Add a JPG or PNG.',
          );
        }
        final bytes = await photo.readBytes();
        if (bytes == null || bytes.isEmpty) {
          throw FormatException('${photo.label ?? 'A photo'} cannot be read.');
        }
        if (bytes.length > 10 * 1024 * 1024) {
          throw FormatException(
            '${photo.label ?? 'A photo'} is larger than 10 MB.',
          );
        }
        final lower = (photo.label ?? photo.path ?? '').toLowerCase();
        final isPng = lower.endsWith('.png');
        final isJpeg = lower.endsWith('.jpg') || lower.endsWith('.jpeg');
        if (!isPng && !isJpeg) {
          throw FormatException(
            '${photo.label ?? 'A photo'} must be JPG or PNG.',
          );
        }
        final extension = isPng ? 'png' : 'jpg';
        final contentType = isPng ? 'image/png' : 'image/jpeg';
        final validSignature = isPng
            ? bytes.length >= 8 &&
                  bytes[0] == 0x89 &&
                  bytes[1] == 0x50 &&
                  bytes[2] == 0x4e &&
                  bytes[3] == 0x47
            : bytes.length >= 3 &&
                  bytes[0] == 0xff &&
                  bytes[1] == 0xd8 &&
                  bytes[2] == 0xff;
        if (!validSignature) {
          throw FormatException(
            '${photo.label ?? 'A photo'} does not contain a valid image.',
          );
        }
        final path =
            '$userId/${DateTime.now().microsecondsSinceEpoch}-$index.$extension';
        await _client.storage
            .from('facility-photos')
            .uploadBinary(
              path,
              bytes,
              fileOptions: FileOptions(contentType: contentType),
            );
        paths.add(path);
        uploaded.add(path);
      }
      return (paths: paths, uploaded: uploaded);
    } catch (_) {
      if (uploaded.isNotEmpty) {
        try {
          await _client.storage.from('facility-photos').remove(uploaded);
        } catch (_) {}
      }
      rethrow;
    }
  }

  @override
  Future<void> archiveFacility(String id) async {
    await _client
        .from('facilities')
        .update({'archived_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id);
  }

  @override
  Future<void> restoreFacility(String id) async {
    await _client.from('facilities').update({'archived_at': null}).eq('id', id);
  }

  @override
  Future<ReportSnapshot> adminReport(ReportScope scope) async {
    final data = await _client.rpc(
      'get_admin_report',
      params: {
        'p_from': scope.from.toUtc().toIso8601String(),
        'p_to': scope.to.toUtc().toIso8601String(),
        'p_category': scope.category,
      },
    );
    if (data is! Map) {
      throw const ReportContractException(
        ReportContractFailureCode.invalidResponse,
      );
    }
    return ReportSnapshot.fromJson(
      Map<String, dynamic>.from(data),
      expectedScope: scope,
    );
  }

  @override
  Future<AuditPage> auditEntries(AuditQuery query) async {
    final data = await _client.rpc(
      'get_audit_entries',
      params: {
        'p_search': query.search.isEmpty ? null : query.search,
        'p_actor': query.actor,
        'p_entity_type': query.entityType,
        'p_material_only': query.materialOnly,
        'p_from': query.from?.toUtc().toIso8601String(),
        'p_to': query.to?.toUtc().toIso8601String(),
        'p_before_created_at': query.beforeCreatedAt?.toUtc().toIso8601String(),
        'p_before_id': query.beforeId,
        'p_limit': query.limit,
      },
    );
    return AuditPage.fromJson(Map<String, dynamic>.from(data as Map));
  }

  @override
  Future<void> recordAuditExport(AuditQuery query, int rowCount) => _client.rpc(
    'record_audit_export',
    params: {'p_row_count': rowCount, 'p_filters': query.filters},
  );

  @override
  Future<void> revertAuditEntry(String entryId, String reason) => _client.rpc(
    'revert_facility_audit_entry',
    params: {'p_entry_id': entryId, 'p_reason': reason},
  );

  Future<void> inviteAdmin({
    required String email,
    required String role,
    String? note,
  }) async {
    await inviteAccountAdmin(email: email, role: role, note: note);
  }

  Future<Map<String, dynamic>> _manageUsers(
    String action, {
    Map<String, dynamic> fields = const {},
  }) async {
    late final FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        'manage-users',
        body: {'action': action, ...fields},
      );
    } on FunctionException catch (error) {
      throw AccountManagementException.fromFunctionException(error);
    }
    final data = response.data;
    if (data is! Map) {
      throw AccountManagementException.invalidResponse(status: response.status);
    }
    final json = Map<String, dynamic>.from(data);
    if (json['error'] != null) {
      final rawCode = json['code'];
      final rawMessage = json['error'];
      final rawRequestId = json['request_id'];
      throw AccountManagementException(
        code: rawCode is String ? rawCode : _accountErrorCode(response.status),
        message: rawMessage is String
            ? rawMessage
            : _accountErrorMessage('request_failed', response.status),
        status: response.status,
        requestId: rawRequestId is String ? rawRequestId : null,
      );
    }
    return json;
  }

  BackendAccount _accountResult(Map<String, dynamic> response) {
    final value = response['account'];
    if (value is! Map) {
      throw const AccountManagementException.invalidResponse();
    }
    try {
      return BackendAccount.fromJson(Map<String, dynamic>.from(value));
    } on FormatException {
      throw const AccountManagementException.invalidResponse();
    }
  }

  Map<String, dynamic> _singleRpcRow(Object? response, String label) {
    if (response is Map) {
      return Map<String, dynamic>.from(response);
    }
    if (response is List && response.length == 1 && response.first is Map) {
      return Map<String, dynamic>.from(response.first as Map);
    }
    throw StateError('$label returned an invalid response.');
  }

  BackendOrganizationUnit _organizationUnitResult(Object? response) =>
      BackendOrganizationUnit.fromJson(
        _singleRpcRow(response, 'Organization unit'),
      );

  Future<BackendOrganizationAccountSlot> _organizationSlotResult(
    Object? response,
  ) async {
    final row = _singleRpcRow(response, 'Organization account slot');
    final assigned = {
      for (final account in await accounts())
        if (account.organizationSlotId != null &&
            account.accountStatus == 'active')
          account.organizationSlotId!: account,
    };
    return BackendOrganizationAccountSlot.fromJson(
      row,
      assignedAccount: assigned[row['id']],
    );
  }

  @override
  Future<List<BackendAccount>> accounts() async {
    final response = await _manageUsers('list');
    final rows = response['accounts'];
    if (rows is! List) {
      throw const AccountManagementException.invalidResponse();
    }
    try {
      return [
        for (final row in rows)
          BackendAccount.fromJson(Map<String, dynamic>.from(row as Map)),
      ];
    } on Object {
      throw const AccountManagementException.invalidResponse();
    }
  }

  @override
  Future<List<BackendAccount>> externalClients() async {
    final response = await _client.rpc('get_external_clients');
    if (response is! List) {
      throw StateError('Client directory returned an invalid response.');
    }
    return [
      for (final row in response)
        BackendAccount.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Stream<List<BackendAccount>> accountStream() => _client
      .from('profiles')
      .stream(primaryKey: ['id'])
      .asyncMap((_) => accounts());

  @override
  Future<BackendAccount> inviteAccountAdmin({
    required String email,
    required String role,
    String? note,
    String? organizationSlotId,
  }) async {
    final fields = <String, dynamic>{'email': email, 'role': role};
    if (organizationSlotId != null) {
      fields['organization_slot_id'] = organizationSlotId;
    }
    if (note != null && note.trim().isNotEmpty) {
      fields['note'] = note.trim();
    }
    return _accountResult(await _manageUsers('invite', fields: fields));
  }

  @override
  Future<BackendCreatedAccount> createAdministrator({
    required String email,
    required String role,
    String? note,
  }) async {
    final fields = <String, dynamic>{'email': email, 'role': role};
    if (note != null && note.trim().isNotEmpty) {
      fields['note'] = note.trim();
    }
    final response = await _manageUsers('create_administrator', fields: fields);
    final temporaryPassword = response['temporary_password'];
    if (temporaryPassword is! String || temporaryPassword.isEmpty) {
      throw StateError('User management did not return temporary credentials.');
    }
    return BackendCreatedAccount(
      account: _accountResult(response),
      temporaryPassword: temporaryPassword,
    );
  }

  @override
  Future<BackendCreatedAccount> createOrganizationRepresentative({
    required String fullName,
    required String email,
    required String organizationSlotId,
  }) async {
    final response = await _manageUsers(
      'create_organization_representative',
      fields: {
        'full_name': fullName,
        'email': email,
        'organization_slot_id': organizationSlotId,
      },
    );
    final temporaryPassword = response['temporary_password'];
    if (temporaryPassword is! String || temporaryPassword.isEmpty) {
      throw StateError('User management did not return temporary credentials.');
    }
    return BackendCreatedAccount(
      account: _accountResult(response),
      temporaryPassword: temporaryPassword,
    );
  }

  @override
  Future<BackendCreatedAccount> resetOrganizationRepresentativePassword(
    String accountId,
  ) async {
    final response = await _manageUsers(
      'reset_organization_representative_password',
      fields: {'target_id': accountId},
    );
    final temporaryPassword = response['temporary_password'];
    if (temporaryPassword is! String || temporaryPassword.isEmpty) {
      throw StateError('User management did not return temporary credentials.');
    }
    return BackendCreatedAccount(
      account: _accountResult(response),
      temporaryPassword: temporaryPassword,
    );
  }

  @override
  Future<List<BackendOrganizationUnit>> organizationUnits() async {
    final response = await _client
        .from('organizational_units')
        .select(
          'id,parent_id,name,code,unit_type,active,requires_representative,booking_audience',
        )
        .order('name');
    return [
      for (final row in response)
        BackendOrganizationUnit.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<List<BackendOrganizationAccountSlot>> organizationSlots() async {
    final rows = await _client
        .from('organization_account_slots')
        .select(
          'id,unit_id,label,active,organizational_units(id,parent_id,name,code,unit_type,active,requires_representative,booking_audience)',
        )
        .order('label');
    final assigned = {
      for (final account in await accounts())
        if (account.organizationSlotId != null &&
            account.accountStatus == 'active')
          account.organizationSlotId!: account,
    };
    return [
      for (final row in rows)
        BackendOrganizationAccountSlot.fromJson(
          Map<String, dynamic>.from(row as Map),
          assignedAccount: assigned[row['id']],
        ),
    ];
  }

  @override
  Future<BackendOrganizationUnit> createOrganizationUnit({
    String? parentId,
    required String name,
    String? code,
    required String unitType,
    required bool requiresRepresentative,
    String? bookingAudience,
  }) async => _organizationUnitResult(
    await _client.rpc(
      'create_organization_unit',
      params: {
        'p_parent_id': parentId,
        'p_name': name,
        'p_code': code,
        'p_unit_type': unitType,
        'p_requires_representative': requiresRepresentative,
        'p_booking_audience': bookingAudience,
      },
    ),
  );

  @override
  Future<BackendOrganizationUnit> updateOrganizationUnit({
    required String unitId,
    String? parentId,
    required String name,
    String? code,
    required String unitType,
    String? bookingAudience,
  }) async => _organizationUnitResult(
    await _client.rpc(
      'update_organization_unit_policy',
      params: {
        'p_unit_id': unitId,
        'p_parent_id': parentId,
        'p_name': name,
        'p_code': code,
        'p_unit_type': unitType,
        'p_booking_audience': bookingAudience,
      },
    ),
  );

  @override
  Future<BackendOrganizationUnit> archiveOrganizationUnit(
    String unitId,
  ) async => _organizationUnitResult(
    await _client.rpc(
      'archive_organization_unit_policy',
      params: {'p_unit_id': unitId},
    ),
  );

  Future<BackendOrganizationAccountSlot> createOrganizationAccountSlot({
    required String unitId,
    required String label,
  }) async => _organizationSlotResult(
    await _client.rpc(
      'create_organization_account_slot',
      params: {'p_unit_id': unitId, 'p_label': label},
    ),
  );

  Future<BackendOrganizationAccountSlot> updateOrganizationAccountSlot({
    required String slotId,
    required String label,
    required bool active,
  }) async => _organizationSlotResult(
    await _client.rpc(
      'update_organization_account_slot',
      params: {'p_slot_id': slotId, 'p_label': label, 'p_active': active},
    ),
  );

  Future<BackendOrganizationAccountSlot> archiveOrganizationAccountSlot(
    String slotId,
  ) async => _organizationSlotResult(
    await _client.rpc(
      'archive_organization_account_slot',
      params: {'p_slot_id': slotId},
    ),
  );

  @override
  Future<BackendAccount> assignOrganizationRepresentative({
    required String profileId,
    required String slotId,
  }) async {
    await _client.rpc(
      'assign_existing_organization_representative',
      params: {'p_profile_id': profileId, 'p_slot_id': slotId},
    );
    final refreshed = await accounts();
    return refreshed.firstWhere(
      (account) => account.id == profileId,
      orElse: () => throw StateError('Assigned account could not be reloaded.'),
    );
  }

  @override
  Future<BackendAccount> transferOrganizationRepresentative({
    required String currentProfileId,
    required String replacementProfileId,
    required String slotId,
  }) async {
    await _client.rpc(
      'transfer_organization_representative',
      params: {
        'p_current_profile_id': currentProfileId,
        'p_replacement_profile_id': replacementProfileId,
        'p_slot_id': slotId,
      },
    );
    final refreshed = await accounts();
    return refreshed.firstWhere(
      (account) => account.id == replacementProfileId,
      orElse: () =>
          throw StateError('Transferred account could not be reloaded.'),
    );
  }

  @override
  Future<BackendAccount> removeOrganizationRepresentative(
    String profileId,
  ) async {
    await _client.rpc(
      'remove_organization_representative',
      params: {'p_profile_id': profileId},
    );
    final refreshed = await accounts();
    return refreshed.firstWhere(
      (account) => account.id == profileId,
      orElse: () => throw StateError('Updated account could not be reloaded.'),
    );
  }

  @override
  Future<BackendAccount> convertLegacyAccountToExternalGuest({
    required String profileId,
    required String reason,
  }) async {
    await _client.rpc(
      'convert_legacy_account_to_external_guest',
      params: {'p_profile_id': profileId, 'p_reason': reason},
    );
    final refreshed = await accounts();
    return refreshed.firstWhere(
      (account) => account.id == profileId,
      orElse: () => throw StateError('Updated account could not be reloaded.'),
    );
  }

  @override
  Future<BackendAccount> resendAdminInvite(String accountId) async =>
      _accountResult(
        await _manageUsers('resend_invite', fields: {'target_id': accountId}),
      );

  @override
  Future<String> revokeAdminInvite(String accountId) async {
    final response = await _manageUsers(
      'revoke_invite',
      fields: {'target_id': accountId},
    );
    return (response['removed_id'] as String?) ?? accountId;
  }

  @override
  Future<BackendAccount> changeAccountRole({
    required String accountId,
    required String role,
  }) async => _accountResult(
    await _manageUsers(
      'change_role',
      fields: {'target_id': accountId, 'role': role},
    ),
  );

  @override
  Future<BackendAccount> suspendUserAccount({
    required String accountId,
    required String reason,
    DateTime? suspendedUntil,
  }) async => _accountResult(
    await _manageUsers(
      'suspend',
      fields: {
        'target_id': accountId,
        'reason': reason,
        if (suspendedUntil != null)
          'suspended_until': _dateOnly(suspendedUntil),
      },
    ),
  );

  @override
  Future<BackendAccount> liftUserSuspension(String accountId) async =>
      _accountResult(
        await _manageUsers('lift_suspension', fields: {'target_id': accountId}),
      );

  @override
  Future<BackendAccount> requestAccountReverification(String accountId) async =>
      _accountResult(
        await _manageUsers(
          'request_reverification',
          fields: {'target_id': accountId},
        ),
      );

  @override
  Future<BackendAccount> sendAccountPasswordReset(String accountId) async =>
      _accountResult(
        await _manageUsers(
          'send_password_reset',
          fields: {'target_id': accountId},
        ),
      );

  String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
