import '../theme/sr_tokens.dart';

enum PermitStatus {
  active('active', 'Active'),
  superseded('superseded', 'Superseded'),
  void_('void', 'Void');

  const PermitStatus(this.raw, this.label);
  final String raw;
  final String label;

  SrTone get tone => switch (this) {
    PermitStatus.active => SrTone.success,
    PermitStatus.superseded => SrTone.neutral,
    PermitStatus.void_ => SrTone.error,
  };

  static PermitStatus fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => PermitStatus.superseded,
  );
}

class PermitOccurrence {
  const PermitOccurrence({required this.startsAt, required this.endsAt});

  final DateTime startsAt;
  final DateTime endsAt;
}

class ReservationPermit {
  const ReservationPermit({
    required this.id,
    required this.requestId,
    required this.permitNumber,
    required this.version,
    required this.status,
    required this.verificationToken,
    required this.issuedAt,
    required this.institutionName,
    required this.formCode,
    required this.requesterName,
    required this.requesterType,
    required this.office,
    required this.facilityName,
    required this.facilityLocation,
    required this.purpose,
    required this.headcount,
    required this.occurrences,
    required this.amenities,
    required this.paymentExemption,
    required this.paymentRequired,
    required this.totalAmountCentavos,
    required this.amountPaidCentavos,
    required this.remainingBalanceCentavos,
    required this.signatoryName,
    required this.signatoryTitle,
    this.approvedByName,
    this.approvedByRole,
    this.approvedAt,
    this.storagePath,
    this.voidedAt,
    this.voidReason,
  });

  final String id;
  final String requestId;
  final String permitNumber;
  final int version;
  final PermitStatus status;
  final String verificationToken;
  final DateTime issuedAt;
  final String institutionName;
  final String formCode;
  final String requesterName;
  final String requesterType;
  final String office;
  final String facilityName;
  final String facilityLocation;
  final String purpose;
  final int headcount;
  final List<PermitOccurrence> occurrences;
  final List<String> amenities;
  final String paymentExemption;
  final bool paymentRequired;
  final int totalAmountCentavos;
  final int amountPaidCentavos;
  final int remainingBalanceCentavos;
  final String signatoryName;
  final String signatoryTitle;
  final String? approvedByName;
  final String? approvedByRole;
  final DateTime? approvedAt;
  final String? storagePath;
  final DateTime? voidedAt;
  final String? voidReason;

  bool get isFullyPaid => remainingBalanceCentavos <= 0;

  /// The only content encoded in the permit's QR: a namespaced opaque token,
  /// never an amount, email, or user id.
  String get verificationPayload => 'smartreserve:permit:$verificationToken';

  factory ReservationPermit.fromJson(Map<String, dynamic> json) {
    final snapshot = Map<String, dynamic>.from(
      (json['snapshot'] as Map?) ?? const {},
    );
    List<PermitOccurrence> occurrences() => [
      for (final raw in (snapshot['occurrences'] as List? ?? const []))
        PermitOccurrence(
          startsAt: DateTime.parse('${(raw as Map)['starts_at']}'),
          endsAt: DateTime.parse('${raw['ends_at']}'),
        ),
    ];
    return ReservationPermit(
      id: '${json['id']}',
      requestId: '${json['request_id']}',
      permitNumber:
          '${json['permit_number'] ?? snapshot['permit_number'] ?? ''}',
      version: (json['version'] as num?)?.toInt() ?? 1,
      status: PermitStatus.fromRaw('${json['status'] ?? 'active'}'),
      verificationToken: '${json['verification_token'] ?? ''}',
      issuedAt: DateTime.parse('${json['issued_at']}'),
      institutionName: '${snapshot['institution_name'] ?? ''}',
      formCode: '${snapshot['form_code'] ?? ''}',
      requesterName: '${snapshot['requester_name'] ?? ''}',
      requesterType: '${snapshot['requester_type'] ?? ''}',
      office: '${snapshot['office'] ?? ''}',
      facilityName: '${snapshot['facility_name'] ?? ''}',
      facilityLocation: '${snapshot['facility_location'] ?? ''}',
      purpose: '${snapshot['purpose'] ?? ''}',
      headcount: (snapshot['headcount'] as num?)?.toInt() ?? 0,
      occurrences: occurrences(),
      amenities: [
        for (final value in (snapshot['amenities'] as List? ?? const []))
          '$value',
      ],
      paymentExemption: '${snapshot['payment_exemption'] ?? 'none'}',
      paymentRequired: snapshot['payment_required'] as bool? ?? false,
      totalAmountCentavos:
          (snapshot['total_amount_centavos'] as num?)?.toInt() ?? 0,
      amountPaidCentavos:
          (snapshot['amount_paid_centavos'] as num?)?.toInt() ?? 0,
      remainingBalanceCentavos:
          (snapshot['remaining_balance_centavos'] as num?)?.toInt() ?? 0,
      signatoryName: '${snapshot['signatory_name'] ?? ''}',
      signatoryTitle: '${snapshot['signatory_title'] ?? ''}',
      approvedByName: snapshot['approved_by_name'] as String?,
      approvedByRole: snapshot['approved_by_role'] as String?,
      approvedAt: snapshot['approved_at'] == null
          ? null
          : DateTime.parse('${snapshot['approved_at']}'),
      storagePath: json['storage_path'] as String?,
      voidedAt: json['voided_at'] == null
          ? null
          : DateTime.parse('${json['voided_at']}'),
      voidReason: json['void_reason'] as String?,
    );
  }
}
