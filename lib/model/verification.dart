import 'decision_check.dart';

enum VerificationDecision { pending, approved, changesRequested, rejected }

class VerificationSubmission {
  VerificationSubmission({
    required this.id,
    required this.name,
    required this.email,
    required this.kind,
    required this.idNumber,
    required this.unit,
    required this.document,
    required this.submitted,
    required this.registryMatch,
    required this.nameMatch,
    required this.alreadyClaimed,
    required this.legible,
    required this.decision,
    this.decidedAt,
    this.reason,
    this.fromOnboarding = false,
    this.userId,
    this.documentPath,
  });

  final String id;
  final String name;
  final String email;

  final String kind;
  final String idNumber;
  final String unit;

  final String document;
  final String submitted;

  final bool registryMatch;
  final bool nameMatch;

  final bool alreadyClaimed;
  final bool legible;

  VerificationDecision decision;
  String? decidedAt;
  String? reason;

  bool fromOnboarding;
  final String? userId;
  final String? documentPath;

  String get initials => name
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .take(2)
      .map((w) => w[0].toUpperCase())
      .join();

  bool get isPending => decision == VerificationDecision.pending;

  bool get bulkApprovable =>
      isPending && registryMatch && nameMatch && legible && !alreadyClaimed;

  List<DecisionCheck> get checks => [
    DecisionCheck(
      label: 'Registry',
      value: registryMatch
          ? 'ID $idNumber found in the current registry.'
          : 'ID $idNumber is not in the current registry.',
      outcome: registryMatch ? CheckOutcome.pass : CheckOutcome.warn,
    ),
    DecisionCheck(
      label: 'Name match',
      value: nameMatch
          ? 'Document name matches the account name.'
          : 'Document name does not match the account name.',
      outcome: nameMatch ? CheckOutcome.pass : CheckOutcome.fail,
    ),
    DecisionCheck(
      label: 'ID reuse',
      value: alreadyClaimed
          ? 'This ID number is already claimed by another account.'
          : 'Not claimed by any other account.',
      outcome: alreadyClaimed ? CheckOutcome.warn : CheckOutcome.pass,
    ),
    DecisionCheck(
      label: 'Document',
      value: legible
          ? 'Legible and within its validity period.'
          : 'Too blurred to read — ask for a clearer photo.',
      outcome: legible ? CheckOutcome.pass : CheckOutcome.warn,
    ),
  ];

  CheckSummary get summary => CheckSummary.of(
    checks,
    clear: 'All four checks passed. Safe to verify.',
    caution: 'Verify only if you are satisfied with the flagged check.',
    blocked: 'The document does not belong to this account.',
  );
}
