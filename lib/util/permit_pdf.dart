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
  final fixed = amount.toStringAsFixed(whole ? 0 : 2);
  final parts = fixed.split('.');
  final digits = parts.first;
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final fromEnd = digits.length - i;
    if (i > 0 && fromEnd % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  final grouped = parts.length > 1 ? '$buffer.${parts[1]}' : '$buffer';
  return 'PHP $grouped';
}

const _ink = PdfColor.fromInt(0xFF1A1A1A);
const _line = PdfColor.fromInt(0xFF4A4A4A);
const _grey = PdfColors.grey700;

/// Recreates the paper "Request Form (A)" as a faithful, dynamic A4 document:
/// a single bordered frame with real ruled boxes, matching the campus form
/// staff already recognise. No signature (the requester's or the
/// signatory's) is drawn -- both are left as blank rules for a physical pen,
/// or left entirely off when the paper form has none.
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

  final fonts = _Fonts(
    regular: regular,
    medium: medium,
    semiBold: semiBold,
    bold: bold,
    mono: mono,
  );

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(30, 28, 30, 28),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(child: _formFrame(permit, fonts)),
          pw.SizedBox(height: 8),
          _recordStrip(permit, fonts),
        ],
      ),
    ),
  );

  return doc.save();
}

class _Fonts {
  const _Fonts({
    required this.regular,
    required this.medium,
    required this.semiBold,
    required this.bold,
    required this.mono,
  });

  final pw.Font regular;
  final pw.Font medium;
  final pw.Font semiBold;
  final pw.Font bold;
  final pw.Font mono;
}

pw.Widget _formFrame(ReservationPermit permit, _Fonts f) => pw.Container(
  width: double.infinity,
  decoration: pw.BoxDecoration(border: pw.Border.all(color: _line, width: 0.9)),
  padding: const pw.EdgeInsets.all(14),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      _formHeader(permit, f),
      pw.SizedBox(height: 10),
      _sirLine(f),
      pw.SizedBox(height: 8),
      _sectionTitles(f),
      pw.SizedBox(height: 4),
      _checklistGrid(permit, f),
      pw.SizedBox(height: 8),
      _metaLine(permit, f),
      pw.SizedBox(height: 8),
      _ruledField(
        'Requested Date of Use:',
        _scheduleValue(permit),
        f,
        maxLines: 2,
      ),
      pw.SizedBox(height: 8),
      _ruledField('Purpose:', permit.purpose, f, maxLines: 2),
      pw.SizedBox(height: 10),
      pw.Text(
        'We assume full responsibility including the expenses that may be '
        'incurred in case of damage or loss during the specified schedule of '
        'use.',
        style: pw.TextStyle(font: f.regular, fontSize: 9.5, lineSpacing: 1.3, color: _ink),
      ),
      pw.SizedBox(height: 14),
      _ruledField('Requested by:', '', f),
      pw.Padding(
        padding: const pw.EdgeInsets.only(left: 68, top: 2),
        child: pw.Text(
          '(Printed name and Signature)',
          style: pw.TextStyle(font: f.regular, fontSize: 8, color: _grey),
        ),
      ),
      pw.SizedBox(height: 10),
      _ruledField(
        'Office/College:',
        permit.office.isEmpty ? '—' : permit.office,
        f,
      ),
      pw.Spacer(),
      pw.Align(
        alignment: pw.Alignment.centerRight,
        child: _approvalBlock(permit, f),
      ),
    ],
  ),
);

pw.Widget _formHeader(ReservationPermit permit, _Fonts f) {
  final issued = campusWallTime(permit.issuedAt);
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            permit.formCode,
            style: pw.TextStyle(font: f.mono, fontSize: 9, color: _grey),
          ),
          pw.SizedBox(
            width: 190,
            child: _ruledField('Date:', formatDay(issued), f, labelWidth: 32),
          ),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Center(
        child: pw.Text(
          permit.institutionName.toUpperCase(),
          style: pw.TextStyle(font: f.bold, fontSize: 13, color: _ink),
        ),
      ),
      pw.SizedBox(height: 3),
      pw.Center(
        child: pw.Text(
          'REQUEST FORM (A)',
          style: pw.TextStyle(font: f.bold, fontSize: 12, color: _ink),
        ),
      ),
      pw.SizedBox(height: 2),
      pw.Center(
        child: pw.Text(
          'Approved Facility Reservation Permit',
          style: pw.TextStyle(font: f.regular, fontSize: 8.5, color: _grey),
        ),
      ),
    ],
  );
}

pw.Widget _sirLine(_Fonts f) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.start,
  children: [
    pw.Text('SIR:', style: pw.TextStyle(font: f.semiBold, fontSize: 10, color: _ink)),
    pw.SizedBox(height: 4),
    pw.Padding(
      padding: const pw.EdgeInsets.only(left: 14),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'We would like to request for the use of:',
            style: pw.TextStyle(font: f.regular, fontSize: 10, color: _ink),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            '(Note: Please check before the item that corresponds to your '
            'request.)',
            style: pw.TextStyle(font: f.regular, fontSize: 8, color: _grey),
          ),
        ],
      ),
    ),
  ],
);

pw.Widget _sectionTitles(_Fonts f) => pw.Row(
  children: [
    pw.Expanded(
      child: pw.Text(
        'A. FACILITIES',
        style: pw.TextStyle(font: f.semiBold, fontSize: 9.5, color: _ink),
      ),
    ),
    pw.SizedBox(width: 12),
    pw.Expanded(
      child: pw.Text(
        'B. EQUIPMENT',
        style: pw.TextStyle(font: f.semiBold, fontSize: 9.5, color: _ink),
      ),
    ),
  ],
);

bool _matches(String haystack, List<String> needles) {
  final lower = haystack.toLowerCase();
  return needles.any(lower.contains);
}

pw.Widget _checklistGrid(ReservationPermit permit, _Fonts f) {
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

  return pw.SizedBox(
    height: 124,
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Expanded(
          child: _checklistBox([
            _checkRow('Audio Visual Room / Main Hall', checked: facilityIsHall, f: f),
            _checkRow('Conference Room', checked: facilityIsConference, f: f),
            pw.Expanded(
              child: _checkRow(
                'Others (please specify):',
                checked: facilityOther,
                value: facilityOther ? permit.facilityName : null,
                isLast: true,
                f: f,
              ),
            ),
          ], f),
        ),
        pw.SizedBox(width: 12),
        pw.Expanded(
          child: _checklistBox([
            _checkRow(
              'Sound System',
              checked: checkedEquipment['Sound System']!,
              f: f,
            ),
            _checkRow(
              'Overhead Projector',
              checked: checkedEquipment['Overhead Projector']!,
              f: f,
            ),
            _checkRow(
              'LCD and Accessories',
              checked: checkedEquipment['LCD and Accessories']!,
              f: f,
            ),
            pw.Expanded(
              child: _checkRow(
                'Others (please specify):',
                checked: otherEquipment.isNotEmpty,
                value: otherEquipment.isEmpty ? null : otherEquipment.join(', '),
                isLast: true,
                f: f,
              ),
            ),
          ], f),
        ),
      ],
    ),
  );
}

pw.Widget _checklistBox(List<pw.Widget> rows, _Fonts f) => pw.Container(
  decoration: pw.BoxDecoration(border: pw.Border.all(color: _line, width: 0.8)),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: rows,
  ),
);

pw.Widget _checkRow(
  String label, {
  required bool checked,
  required _Fonts f,
  String? value,
  bool isLast = false,
}) {
  final content = pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
    alignment: pw.Alignment.centerLeft,
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      mainAxisAlignment: pw.MainAxisAlignment.center,
      children: [
        pw.Text(
          label,
          maxLines: 2,
          overflow: pw.TextOverflow.clip,
          style: pw.TextStyle(font: f.medium, fontSize: 9.5, color: _ink),
        ),
        if (value != null && value.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 2),
            child: pw.Text(
              value,
              maxLines: 2,
              overflow: pw.TextOverflow.clip,
              style: pw.TextStyle(font: f.semiBold, fontSize: 9.5, color: _ink),
            ),
          ),
      ],
    ),
  );

  final row = pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Container(
        width: 20,
        alignment: pw.Alignment.center,
        decoration: const pw.BoxDecoration(
          border: pw.Border(right: pw.BorderSide(color: _line, width: 0.7)),
        ),
        child: checked
            ? pw.Text('X', style: pw.TextStyle(font: f.semiBold, fontSize: 9, color: _ink))
            : null,
      ),
      pw.Expanded(child: content),
    ],
  );

  return pw.Container(
    height: 26,
    decoration: isLast
        ? null
        : const pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(color: _line, width: 0.7)),
          ),
    child: row,
  );
}

pw.Widget _metaLine(ReservationPermit permit, _Fonts f) {
  final parts = <String>[
    if (permit.facilityLocation.isNotEmpty) 'Location: ${permit.facilityLocation}',
    'Headcount: ${permit.headcount}',
    'Requester: ${permit.requesterType}',
  ];
  return pw.Text(
    parts.join('  ·  '),
    style: pw.TextStyle(font: f.regular, fontSize: 8.5, color: _grey),
  );
}

String _clock(DateTime value) {
  final hour12 = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final period = value.hour >= 12 ? 'PM' : 'AM';
  return '$hour12:${value.minute.toString().padLeft(2, '0')} $period';
}

String _scheduleValue(ReservationPermit permit) {
  final occurrences = permit.occurrences;
  if (occurrences.isEmpty) return '—';

  String line(PermitOccurrence occurrence) {
    final start = campusWallTime(occurrence.startsAt);
    final end = campusWallTime(occurrence.endsAt);
    return '${formatDay(start)} · ${_clock(start)} – ${_clock(end)}';
  }

  if (occurrences.length <= 4) {
    return occurrences.map(line).join('; ');
  }

  final starts = occurrences.map((o) => campusWallTime(o.startsAt)).toList()
    ..sort();
  final sameTimeOfDay = occurrences.every(
    (o) =>
        campusWallTime(o.startsAt).hour == campusWallTime(occurrences.first.startsAt).hour &&
        campusWallTime(o.startsAt).minute == campusWallTime(occurrences.first.startsAt).minute &&
        campusWallTime(o.endsAt).hour == campusWallTime(occurrences.first.endsAt).hour &&
        campusWallTime(o.endsAt).minute == campusWallTime(occurrences.first.endsAt).minute,
  );
  final range =
      '${formatDay(starts.first)} – ${formatDay(starts.last)}';
  if (sameTimeOfDay) {
    final first = campusWallTime(occurrences.first.startsAt);
    final firstEnd = campusWallTime(occurrences.first.endsAt);
    return '${occurrences.length} dates · $range · ${_clock(first)} – ${_clock(firstEnd)}';
  }
  return '${occurrences.length} dates · $range · varied times';
}

pw.Widget _ruledField(
  String label,
  String value,
  _Fonts f, {
  int maxLines = 1,
  double? labelWidth,
}) => pw.Row(
  crossAxisAlignment: pw.CrossAxisAlignment.end,
  children: [
    pw.SizedBox(
      width: labelWidth,
      child: pw.Text(
        label,
        style: pw.TextStyle(font: f.semiBold, fontSize: 9.5, color: _ink),
      ),
    ),
    pw.SizedBox(width: 6),
    pw.Expanded(
      child: pw.Container(
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _line, width: 0.7)),
        ),
        padding: const pw.EdgeInsets.only(bottom: 2, left: 2),
        child: pw.Text(
          value,
          maxLines: maxLines,
          overflow: pw.TextOverflow.clip,
          style: pw.TextStyle(font: f.regular, fontSize: 9.5, color: _ink),
        ),
      ),
    ),
  ],
);

pw.Widget _approvalBlock(ReservationPermit permit, _Fonts f) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.end,
  children: [
    pw.Text('APPROVED:', style: pw.TextStyle(font: f.semiBold, fontSize: 10, color: _ink)),
    pw.SizedBox(height: 26),
    pw.Text(
      permit.signatoryName,
      style: pw.TextStyle(font: f.bold, fontSize: 10.5, color: _ink),
    ),
    pw.Text(
      permit.signatoryTitle,
      style: pw.TextStyle(font: f.regular, fontSize: 9, color: _grey),
    ),
  ],
);

String _roleLabel(String role) => switch (role) {
  'internal_admin' => 'Internal Administrator',
  'external_admin' => 'External Administrator',
  _ => role,
};

pw.Widget _recordStrip(ReservationPermit permit, _Fonts f) {
  final approvedAt = permit.approvedAt == null ? null : campusWallTime(permit.approvedAt!);

  String paymentLine() {
    if (!permit.paymentRequired) {
      final reason = switch (permit.paymentExemption) {
        'verified_student' => 'Verified Student',
        'verified_faculty' => 'Verified Faculty',
        _ => 'Not Required',
      };
      return 'Payment: NOT REQUIRED ($reason)';
    }
    final buffer = StringBuffer(
      'Payment: ${permit.isFullyPaid ? 'FULLY PAID' : 'PARTIALLY PAID'} · '
      'Total ${_php(permit.totalAmountCentavos)}',
    );
    if (permit.remainingBalanceCentavos > 0) {
      buffer.write(' · Balance ${_php(permit.remainingBalanceCentavos)}');
    }
    return buffer.toString();
  }

  return pw.Container(
    decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400, width: 0.7)),
    padding: const pw.EdgeInsets.all(8),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.BarcodeWidget(
          barcode: pw.Barcode.qrCode(),
          data: permit.verificationPayload,
          width: 46,
          height: 46,
        ),
        pw.SizedBox(width: 10),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Permit No. ${permit.permitNumber} · v${permit.version} · '
                'Ref ${permit.requestId.substring(0, 8)}',
                style: pw.TextStyle(font: f.mono, fontSize: 8, color: _grey),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                'Scan to verify. Present this printed permit at the facility.',
                style: pw.TextStyle(font: f.regular, fontSize: 8.5, color: _ink),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                paymentLine(),
                style: pw.TextStyle(font: f.semiBold, fontSize: 8.5, color: _ink),
              ),
              if (permit.approvedByName != null) ...[
                pw.SizedBox(height: 2),
                pw.Text(
                  'Electronically approved by ${permit.approvedByName}'
                  '${permit.approvedByRole == null ? '' : ', ${_roleLabel(permit.approvedByRole!)}'}'
                  '${approvedAt == null ? '' : ' on ${formatStamp(approvedAt)} (PHT)'}',
                  style: pw.TextStyle(font: f.regular, fontSize: 8, color: _grey),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
