import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/permit.dart';
import 'package:smartreserve/util/permit_pdf.dart';

ReservationPermit _permit({
  required bool paymentRequired,
  String paymentExemption = 'none',
  int totalAmountCentavos = 0,
  int amountPaidCentavos = 0,
}) => ReservationPermit(
  id: 'permit-1',
  requestId: '11111111-2222-3333-4444-555555555555',
  permitNumber: 'SR-2026-000123',
  version: 1,
  status: PermitStatus.active,
  verificationToken: 'a' * 32,
  issuedAt: DateTime.utc(2026, 8, 24, 1, 14),
  institutionName: 'Cagayan State University - Aparri Campus',
  formCode: 'F-UCEO-8001',
  requesterName: 'Aragon C. Cabalbag',
  requesterType: paymentExemption == 'none' ? 'External Renter' : 'Verified Student',
  office: 'CICS',
  facilityName: 'Gymplex',
  facilityLocation: 'Main Building · Court A',
  purpose: 'Practice for Cultural Show (CICS)',
  headcount: 40,
  occurrences: [
    PermitOccurrence(
      startsAt: DateTime.utc(2026, 10, 29, 5), // 1:00 PM PHT
      endsAt: DateTime.utc(2026, 10, 29, 9), // 5:00 PM PHT
    ),
  ],
  amenities: const ['Sound System', 'Ceiling Fans'],
  paymentExemption: paymentExemption,
  paymentRequired: paymentRequired,
  totalAmountCentavos: totalAmountCentavos,
  amountPaidCentavos: amountPaidCentavos,
  remainingBalanceCentavos: totalAmountCentavos - amountPaidCentavos,
  signatoryName: 'AUDY R. QUEBRAL, PECE, JD, DPA',
  signatoryTitle: 'Campus Executive Officer',
  approvedByName: 'Admin Example',
  approvedByRole: 'internal_admin',
  approvedAt: DateTime.utc(2026, 8, 24, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds a non-empty PDF for an exempt reservation', () async {
    final permit = _permit(
      paymentRequired: false,
      paymentExemption: 'verified_student',
    );
    final bytes = await buildPermitPdf(permit);
    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('builds a non-empty PDF for a fully paid external renter', () async {
    final permit = _permit(
      paymentRequired: true,
      totalAmountCentavos: 1000000,
      amountPaidCentavos: 1000000,
    );
    final bytes = await buildPermitPdf(permit);
    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('verification payload carries only the opaque token', () {
    final permit = _permit(paymentRequired: false, paymentExemption: 'verified_faculty');
    expect(permit.verificationPayload, 'smartreserve:permit:${'a' * 32}');
  });
}
