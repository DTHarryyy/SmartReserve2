import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../model/permit.dart';
import 'campus_calendar.dart';

/// Spells out "PHP" rather than the peso sign (U+20B1): the sign is an
/// uncommon glyph outside PHP-market fonts, and this document has no
/// reliable way to confirm the embedded font covers it, so this avoids the
/// gamble on an official, printed document.
String _php(int centavos) {
  final amount = centavos / 100;
  final whole = amount == amount.roundToDouble();
  return 'PHP ${amount.toStringAsFixed(whole ? 0 : 2)}';
}

/// Recreates the paper "Request Form (A)" as a clean, dynamic A4 document.
/// The scan is a structural reference only -- nothing here is a background
/// image, and no signature (the requester's or the signatory's) is drawn;
/// both are left as blank rules for a physical pen.
Future<Uint8List> buildPermitPdf(ReservationPermit permit) async {
  final regular = pw.Font.ttf(
    await rootBundle.load('assets/fonts/IBMPlexSans-Regular.ttf'),
  );
  final medium = pw.Font.ttf(
    await rootBundle.load('assets/fonts/IBMPlexSans-Medium.ttf'),
  );
  final semiBold = pw.Font.ttf(
    await rootBundle.load('assets/fonts/IBMPlexSans-SemiBold.ttf'),
  );
  final bold = pw.Font.ttf(
    await rootBundle.load('assets/fonts/IBMPlexSans-Bold.ttf'),
  );
  final mono = pw.Font.ttf(
    await rootBundle.load('assets/fonts/IBMPlexMono-Regular.ttf'),
  );

  final doc = pw.Document(
    theme: pw.ThemeData.withFont(base: regular, bold: semiBold),
  );

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 34, 36, 34),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _header(permit, regular: regular, bold: bold, mono: mono),
          _rule(),
          pw.SizedBox(height: 10),
          _requestSection(permit, regular: regular, semiBold: semiBold),
          pw.SizedBox(height: 12),
          _facilitiesAndEquipment(
            permit,
            regular: regular,
            medium: medium,
            semiBold: semiBold,
          ),
          pw.SizedBox(height: 12),
          _scheduleAndPurpose(permit, regular: regular, semiBold: semiBold),
          pw.SizedBox(height: 12),
          _rule(),
          pw.SizedBox(height: 10),
          _undertaking(permit, regular: regular),
          pw.SizedBox(height: 10),
          _rule(),
          pw.SizedBox(height: 10),
          _paymentBlock(permit, regular: regular, semiBold: semiBold, bold: bold),
          pw.SizedBox(height: 10),
          _rule(),
          pw.SizedBox(height: 10),
          _approvalBlock(permit, regular: regular, semiBold: semiBold, bold: bold),
          pw.Spacer(),
          _rule(),
          pw.SizedBox(height: 8),
          _verificationFooter(permit, regular: regular, mono: mono),
        ],
      ),
    ),
  );

  return doc.save();
}

pw.Widget _rule() =>
    pw.Container(height: 1, color: PdfColor.fromInt(0xFFDDDDDD));

pw.Widget _header(
  ReservationPermit permit, {
  required pw.Font regular,
  required pw.Font bold,
  required pw.Font mono,
}) {
  final issued = campusWallTime(permit.issuedAt);
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            permit.formCode,
            style: pw.TextStyle(font: mono, fontSize: 9, color: PdfColors.grey700),
          ),
          pw.Text(
            'Date: ${formatDay(issued)}',
            style: pw.TextStyle(font: regular, fontSize: 9.5),
          ),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Center(
        child: pw.Text(
          permit.institutionName.toUpperCase(),
          style: pw.TextStyle(font: bold, fontSize: 14),
        ),
      ),
      pw.SizedBox(height: 3),
      pw.Center(
        child: pw.Text(
          'APPROVED FACILITY RESERVATION PERMIT',
          style: pw.TextStyle(font: bold, fontSize: 11.5),
        ),
      ),
      pw.SizedBox(height: 2),
      pw.Center(
        child: pw.Text(
          '(Request Form A)',
          style: pw.TextStyle(font: regular, fontSize: 9, color: PdfColors.grey700),
        ),
      ),
      pw.SizedBox(height: 8),
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'Permit No. ${permit.permitNumber}',
            style: pw.TextStyle(font: bold, fontSize: 10),
          ),
          pw.Text(
            'Reservation Ref. ${permit.requestId.substring(0, 8)}',
            style: pw.TextStyle(font: mono, fontSize: 9, color: PdfColors.grey700),
          ),
        ],
      ),
    ],
  );
}

pw.Widget _requestSection(
  ReservationPermit permit, {
  required pw.Font regular,
  required pw.Font semiBold,
}) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.start,
  children: [
    pw.Text('SIR:', style: pw.TextStyle(font: semiBold, fontSize: 10)),
    pw.SizedBox(height: 4),
    pw.Padding(
      padding: const pw.EdgeInsets.only(left: 14),
      child: pw.Text(
        'We would like to request for the use of:',
        style: pw.TextStyle(font: regular, fontSize: 10),
      ),
    ),
  ],
);

bool _matches(String haystack, List<String> needles) {
  final lower = haystack.toLowerCase();
  return needles.any(lower.contains);
}

pw.Widget _facilitiesAndEquipment(
  ReservationPermit permit, {
  required pw.Font regular,
  required pw.Font medium,
  required pw.Font semiBold,
}) {
  final facilityIsHall = _matches(permit.facilityName, ['audio', 'hall']);
  final facilityIsConference = _matches(permit.facilityName, ['conference']);
  final facilityOther = !facilityIsHall && !facilityIsConference;

  const knownEquipment = {
    'Sound System': ['sound'],
    'Overhead Projector': ['overhead', 'projector'],
    'LCD and Accessories': ['lcd'],
  };
  final matchedAmenities = <String>{};
  final checkedEquipment = <String, bool>{};
  for (final entry in knownEquipment.entries) {
    final hit = permit.amenities.any((amenity) {
      final matched = _matches(amenity, entry.value);
      if (matched) matchedAmenities.add(amenity);
      return matched;
    });
    checkedEquipment[entry.key] = hit;
  }
  final otherEquipment = permit.amenities
      .where((amenity) => !matchedAmenities.contains(amenity))
      .toList();

  pw.Widget checkboxRow(
    String label, {
    required bool checked,
    String? note,
    bool isLast = false,
  }) => pw.Container(
    decoration: isLast
        ? null
        : const pw.BoxDecoration(
            border: pw.Border(
              bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.6),
            ),
          ),
    padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Container(
          width: 12,
          height: 12,
          margin: const pw.EdgeInsets.only(right: 8, top: 1),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey600, width: 0.8),
          ),
          child: checked
              ? pw.Center(
                  child: pw.Text(
                    'X',
                    style: pw.TextStyle(font: semiBold, fontSize: 8.5),
                  ),
                )
              : null,
        ),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(label, style: pw.TextStyle(font: medium, fontSize: 9.5)),
              if (note != null && note.isNotEmpty)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(top: 2),
                  child: pw.Text(
                    note,
                    style: pw.TextStyle(font: semiBold, fontSize: 9.5),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  pw.Widget columnBox(String title, List<pw.Widget> rows) => pw.Expanded(
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(title, style: pw.TextStyle(font: semiBold, fontSize: 9.5)),
        pw.SizedBox(height: 4),
        pw.Container(
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey500, width: 0.8),
          ),
          child: pw.Column(children: rows),
        ),
      ],
    ),
  );

  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      columnBox('A. FACILITIES', [
        checkboxRow('Audio Visual Room / Main Hall', checked: facilityIsHall),
        checkboxRow('Conference Room', checked: facilityIsConference),
        checkboxRow(
          'Others (please specify):',
          checked: facilityOther,
          note: facilityOther ? permit.facilityName : null,
          isLast: true,
        ),
      ]),
      pw.SizedBox(width: 12),
      columnBox('B. EQUIPMENT', [
        checkboxRow('Sound System', checked: checkedEquipment['Sound System']!),
        checkboxRow(
          'Overhead Projector',
          checked: checkedEquipment['Overhead Projector']!,
        ),
        checkboxRow(
          'LCD and Accessories',
          checked: checkedEquipment['LCD and Accessories']!,
        ),
        checkboxRow(
          'Others (please specify):',
          checked: otherEquipment.isNotEmpty,
          note: otherEquipment.isEmpty ? null : otherEquipment.join(', '),
          isLast: true,
        ),
      ]),
    ],
  );
}

pw.Widget _scheduleAndPurpose(
  ReservationPermit permit, {
  required pw.Font regular,
  required pw.Font semiBold,
}) {
  String scheduleLine(PermitOccurrence occurrence) {
    final start = campusWallTime(occurrence.startsAt);
    final end = campusWallTime(occurrence.endsAt);
    String clock(DateTime value) {
      final hour12 = value.hour % 12 == 0 ? 12 : value.hour % 12;
      final period = value.hour >= 12 ? 'PM' : 'AM';
      return '$hour12:${value.minute.toString().padLeft(2, '0')} $period';
    }

    return '${formatDay(start)} · ${clock(start)} – ${clock(end)}';
  }

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      if (permit.facilityLocation.isNotEmpty) ...[
        pw.Text(
          'Facility Location: ${permit.facilityLocation}',
          style: pw.TextStyle(font: regular, fontSize: 9.5),
        ),
        pw.SizedBox(height: 6),
      ],
      pw.Text(
        'Requested Date of Use:',
        style: pw.TextStyle(font: semiBold, fontSize: 9.5),
      ),
      pw.SizedBox(height: 3),
      ...permit.occurrences.map(
        (occurrence) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 2),
          child: pw.Text(
            scheduleLine(occurrence),
            style: pw.TextStyle(font: regular, fontSize: 9.5),
          ),
        ),
      ),
      pw.SizedBox(height: 8),
      pw.Text('Purpose:', style: pw.TextStyle(font: semiBold, fontSize: 9.5)),
      pw.SizedBox(height: 3),
      pw.Text(permit.purpose, style: pw.TextStyle(font: regular, fontSize: 9.5)),
      pw.SizedBox(height: 6),
      pw.Text(
        'Headcount: ${permit.headcount}  ·  Requester type: ${permit.requesterType}',
        style: pw.TextStyle(font: regular, fontSize: 9, color: PdfColors.grey700),
      ),
    ],
  );
}

pw.Widget _undertaking(
  ReservationPermit permit, {
  required pw.Font regular,
}) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.start,
  children: [
    pw.Text(
      'We assume full responsibility including the expenses that may be '
      'incurred in case of damage or loss during the specified schedule of '
      'use.',
      style: pw.TextStyle(font: regular, fontSize: 9.5, lineSpacing: 1.3),
    ),
    pw.SizedBox(height: 18),
    pw.Text(
      'Requested by: ______________________________',
      style: pw.TextStyle(font: regular, fontSize: 10),
    ),
    pw.SizedBox(height: 2),
    pw.Padding(
      padding: const pw.EdgeInsets.only(left: 62),
      child: pw.Text(
        '(Printed name and Signature)',
        style: pw.TextStyle(font: regular, fontSize: 8, color: PdfColors.grey700),
      ),
    ),
    pw.SizedBox(height: 8),
    pw.Text(
      'Office/College: ${permit.office.isEmpty ? '—' : permit.office}',
      style: pw.TextStyle(font: regular, fontSize: 9.5),
    ),
  ],
);

pw.Widget _paymentBlock(
  ReservationPermit permit, {
  required pw.Font regular,
  required pw.Font semiBold,
  required pw.Font bold,
}) {
  if (!permit.paymentRequired) {
    final reason = switch (permit.paymentExemption) {
      'verified_student' => 'Verified Student',
      'verified_faculty' => 'Verified Faculty',
      _ => 'Not Required',
    };
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Payment Requirement: NOT REQUIRED',
          style: pw.TextStyle(font: semiBold, fontSize: 10),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          'Reason: $reason',
          style: pw.TextStyle(font: regular, fontSize: 9.5),
        ),
      ],
    );
  }
  pw.Widget row(String label, String value, {bool emphasize = false}) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 3),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(label, style: pw.TextStyle(font: regular, fontSize: 9.5)),
        pw.Text(
          value,
          style: pw.TextStyle(
            font: emphasize ? bold : semiBold,
            fontSize: 9.5,
          ),
        ),
      ],
    ),
  );
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      row('Reservation Total', _php(permit.totalAmountCentavos)),
      row('Amount Paid', _php(permit.amountPaidCentavos)),
      row('Remaining Balance', _php(permit.remainingBalanceCentavos)),
      row('Payment Status', 'FULLY PAID', emphasize: true),
    ],
  );
}

pw.Widget _approvalBlock(
  ReservationPermit permit, {
  required pw.Font regular,
  required pw.Font semiBold,
  required pw.Font bold,
}) {
  final approvedAt = permit.approvedAt == null
      ? null
      : campusWallTime(permit.approvedAt!);
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.center,
    children: [
      pw.Text('APPROVED:', style: pw.TextStyle(font: semiBold, fontSize: 10)),
      pw.SizedBox(height: 20),
      pw.Text(
        '____________________',
        style: pw.TextStyle(font: regular, fontSize: 10),
      ),
      pw.SizedBox(height: 3),
      pw.Text(
        permit.signatoryName,
        style: pw.TextStyle(font: bold, fontSize: 10),
      ),
      pw.Text(
        permit.signatoryTitle,
        style: pw.TextStyle(font: regular, fontSize: 9, color: PdfColors.grey700),
      ),
      pw.SizedBox(height: 12),
      if (permit.approvedByName != null)
        pw.Column(
          children: [
            pw.Text(
              'Electronically approved in SmartReserve by',
              style: pw.TextStyle(font: regular, fontSize: 8.5, color: PdfColors.grey700),
            ),
            pw.Text(
              '${permit.approvedByName}'
              '${permit.approvedByRole == null ? '' : ', ${_roleLabel(permit.approvedByRole!)}'}',
              style: pw.TextStyle(font: semiBold, fontSize: 9),
            ),
            if (approvedAt != null)
              pw.Text(
                'on ${formatStamp(approvedAt)} (PHT)',
                style: pw.TextStyle(font: regular, fontSize: 8.5, color: PdfColors.grey700),
              ),
          ],
        ),
    ],
  );
}

String _roleLabel(String role) => switch (role) {
  'internal_admin' => 'Internal Administrator',
  'external_admin' => 'External Administrator',
  _ => role,
};

pw.Widget _verificationFooter(
  ReservationPermit permit, {
  required pw.Font regular,
  required pw.Font mono,
}) => pw.Row(
  crossAxisAlignment: pw.CrossAxisAlignment.center,
  children: [
    pw.BarcodeWidget(
      barcode: pw.Barcode.qrCode(),
      data: permit.verificationPayload,
      width: 52,
      height: 52,
    ),
    pw.SizedBox(width: 10),
    pw.Expanded(
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'Scan to verify this permit.',
            style: pw.TextStyle(font: regular, fontSize: 8.5),
          ),
          pw.Text(
            'Present this printed permit at the facility.',
            style: pw.TextStyle(font: regular, fontSize: 8.5),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            '${permit.permitNumber} · v${permit.version}',
            style: pw.TextStyle(font: mono, fontSize: 8, color: PdfColors.grey700),
          ),
        ],
      ),
    ),
  ],
);
