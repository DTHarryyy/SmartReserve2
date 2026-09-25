enum PaymentPurpose {
  downPayment('down_payment', 'Down payment'),
  balance('balance', 'Remaining balance'),
  adjustment('adjustment', 'Adjustment'),
  refund('refund', 'Refund');

  const PaymentPurpose(this.raw, this.label);
  final String raw;
  final String label;

  static PaymentPurpose fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => PaymentPurpose.downPayment,
  );
}

enum PaymentDecisionStatus {
  submitted('submitted', 'Submitted'),
  needsCorrection('needs_correction', 'Needs correction'),
  verified('verified', 'Verified'),
  rejected('rejected', 'Rejected'),
  voided('voided', 'Voided'),
  refunded('refunded', 'Refunded');

  const PaymentDecisionStatus(this.raw, this.label);
  final String raw;
  final String label;

  static PaymentDecisionStatus fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => PaymentDecisionStatus.submitted,
  );
}

enum AggregatePaymentStatus {
  notRequired('not_required', 'No payment required'),
  unpaid('unpaid', 'Payment required'),
  submitted('submitted', 'Payment under review'),
  needsCorrection('needs_correction', 'Payment needs correction'),
  partiallyPaid('partially_paid', 'Partially paid'),
  downPaymentVerified('down_payment_verified', 'Down payment verified'),
  overdue('overdue', 'Overdue'),
  fullyPaid('fully_paid', 'Fully paid');

  const AggregatePaymentStatus(this.raw, this.label);
  final String raw;
  final String label;

  static AggregatePaymentStatus fromRaw(String raw) => values.firstWhere(
    (value) => value.raw == raw,
    orElse: () => AggregatePaymentStatus.unpaid,
  );
}

/// A published destination a renter can pay to. `gcash` is the wallet transfer;
/// `walk_in` is paying cash at the campus cashier and uploading the registrar
/// receipt instead of a GCash screenshot.
class FacilityPaymentMethod {
  const FacilityPaymentMethod({
    required this.id,
    required this.facilityId,
    required this.accountName,
    required this.accountNumber,
    required this.instructions,
    this.methodType = 'gcash',
    this.enabled = true,
  });

  final String id;
  final String facilityId;
  final String methodType;
  final String accountName;
  final String accountNumber;
  final String instructions;
  final bool enabled;

  bool get isWalkIn => methodType == 'walk_in';

  /// Short label for pickers and review rows.
  String get label => isWalkIn ? 'Walk-in (cashier)' : 'GCash';

  /// What the renter types into the reference field for this method.
  String get referenceLabel =>
      isWalkIn ? 'Receipt / OR number' : 'GCash reference number';

  /// Minimum length the backend enforces on [referenceLabel].
  int get referenceMinLength => isWalkIn ? 3 : 6;

  String get proofLabel => isWalkIn
      ? 'Choose registrar receipt photo'
      : 'Choose receipt or screenshot';
}

class PaymentTransaction {
  const PaymentTransaction({
    required this.id,
    required this.requestId,
    required this.payerId,
    required this.purpose,
    required this.amountCentavos,
    required this.referenceNumber,
    required this.proofPath,
    required this.status,
    required this.submittedAt,
    this.paymentMethodId,
    this.verifiedBy,
    this.verifiedAt,
    this.rejectionReason,
    this.correctionDueAt,
    this.correctionCount = 0,
    this.lastCorrectedAt,
  });

  final String id;
  final String requestId;
  final String payerId;
  final PaymentPurpose purpose;
  final int amountCentavos;
  final String referenceNumber;
  final String proofPath;
  final PaymentDecisionStatus status;
  final DateTime submittedAt;
  final String? paymentMethodId;
  final String? verifiedBy;
  final DateTime? verifiedAt;
  final String? rejectionReason;
  final DateTime? correctionDueAt;
  final int correctionCount;
  final DateTime? lastCorrectedAt;
}

class PaymentSummary {
  const PaymentSummary({
    required this.status,
    required this.totalAmountCentavos,
    required this.requiredDownPaymentCentavos,
    required this.verifiedAmountCentavos,
    required this.submittedAmountCentavos,
    required this.outstandingAmountCentavos,
    this.paymentDueAt,
    this.balanceDueAt,
    this.downPaymentPercent = 50,
    this.paymentExemption = 'none',
    this.correctionAmountCentavos = 0,
  });

  final AggregatePaymentStatus status;
  final int totalAmountCentavos;
  final int requiredDownPaymentCentavos;
  final int verifiedAmountCentavos;
  final int submittedAmountCentavos;
  final int outstandingAmountCentavos;
  final DateTime? paymentDueAt;
  final DateTime? balanceDueAt;
  final int downPaymentPercent;
  final String paymentExemption;
  final int correctionAmountCentavos;
}

class PriceSnapshotLine {
  const PriceSnapshotLine({
    required this.type,
    required this.label,
    required this.quantity,
    required this.unitAmountCentavos,
    required this.totalCentavos,
  });

  final String type;
  final String label;
  final double quantity;
  final int unitAmountCentavos;
  final int totalCentavos;
}

class AcceptedTerms {
  const AcceptedTerms({
    required this.id,
    required this.title,
    required this.version,
    required this.content,
    required this.contentHash,
    required this.acceptedAt,
  });

  final String id;
  final String title;
  final int version;
  final String content;
  final String contentHash;
  final DateTime acceptedAt;
}

String pesoFromCentavos(int centavos) {
  final amount = centavos / 100;
  final whole = amount == amount.roundToDouble();
  return '₱${amount.toStringAsFixed(whole ? 0 : 2)}';
}
