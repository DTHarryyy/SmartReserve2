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

  test('does not overflow with many occurrences spanning months', () async {
    final base = _permit(paymentRequired: false, paymentExemption: 'verified_student');
    final occurrences = [
      for (var i = 0; i < 30; i++)
        PermitOccurrence(
          startsAt: DateTime.utc(2026, 9, 1 + i, 5),
          endsAt: DateTime.utc(2026, 9, 1 + i, 9),
        ),
    ];
    final permit = ReservationPermit(
      id: base.id,
      requestId: base.requestId,
      permitNumber: base.permitNumber,
      version: base.version,
      status: base.status,
      verificationToken: base.verificationToken,
      issuedAt: base.issuedAt,
      institutionName: base.institutionName,
      formCode: base.formCode,
      requesterName: base.requesterName,
      requesterType: base.requesterType,
      office: base.office,
      facilityName: base.facilityName,
      facilityLocation: base.facilityLocation,
      purpose: base.purpose,
      headcount: base.headcount,
      occurrences: occurrences,
      amenities: base.amenities,
      paymentExemption: base.paymentExemption,
      paymentRequired: base.paymentRequired,
      totalAmountCentavos: base.totalAmountCentavos,
      amountPaidCentavos: base.amountPaidCentavos,
      remainingBalanceCentavos: base.remainingBalanceCentavos,
      signatoryName: base.signatoryName,
      signatoryTitle: base.signatoryTitle,
      approvedByName: base.approvedByName,
      approvedByRole: base.approvedByRole,
      approvedAt: base.approvedAt,
    );
    final bytes = await buildPermitPdf(permit);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('does not overflow with long purpose and facility name', () async {
    final long = List.filled(60, 'word').join(' ');
    final base = _permit(paymentRequired: false, paymentExemption: 'verified_student');
    final permit = ReservationPermit(
      id: base.id,
      requestId: base.requestId,
      permitNumber: base.permitNumber,
      version: base.version,
      status: base.status,
      verificationToken: base.verificationToken,
      issuedAt: base.issuedAt,
      institutionName: base.institutionName,
      formCode: base.formCode,
      requesterName: base.requesterName,
      requesterType: base.requesterType,
      office: base.office,
      facilityName: 'A very long unmatched facility name that keeps going $long',
      facilityLocation: base.facilityLocation,
      purpose: long,
      headcount: base.headcount,
      occurrences: base.occurrences,
      amenities: const [
        'Ceiling Fans',
        'Extra Tables',
        'Extra Chairs',
        'Extension Cords',
        'Portable Stage',
        'Backdrop Panels',
        'Podium',
        'Whiteboard',
        'Extra Trash Bins',
        'Bunting Flags',
      ],
      paymentExemption: base.paymentExemption,
      paymentRequired: base.paymentRequired,
      totalAmountCentavos: base.totalAmountCentavos,
      amountPaidCentavos: base.amountPaidCentavos,
      remainingBalanceCentavos: base.remainingBalanceCentavos,
      signatoryName: base.signatoryName,
      signatoryTitle: base.signatoryTitle,
      approvedByName: null,
      approvedByRole: null,
      approvedAt: null,
    );
    final bytes = await buildPermitPdf(permit);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('does not overflow with empty office and facility location', () async {
    final base = _permit(paymentRequired: true, totalAmountCentavos: 500000);
    final permit = ReservationPermit(
      id: base.id,
      requestId: base.requestId,
      permitNumber: base.permitNumber,
      version: base.version,
      status: base.status,
      verificationToken: base.verificationToken,
      issuedAt: base.issuedAt,
      institutionName: base.institutionName,
      formCode: base.formCode,
      requesterName: base.requesterName,
      requesterType: base.requesterType,
      office: '',
      facilityName: base.facilityName,
      facilityLocation: '',
      purpose: base.purpose,
      headcount: base.headcount,
      occurrences: base.occurrences,
      amenities: base.amenities,
      paymentExemption: base.paymentExemption,
      paymentRequired: base.paymentRequired,
      totalAmountCentavos: base.totalAmountCentavos,
      amountPaidCentavos: base.amountPaidCentavos,
      remainingBalanceCentavos: base.remainingBalanceCentavos,
      signatoryName: base.signatoryName,
      signatoryTitle: base.signatoryTitle,
      approvedByName: null,
      approvedByRole: null,
      approvedAt: null,
    );
    final bytes = await buildPermitPdf(permit);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });
}
