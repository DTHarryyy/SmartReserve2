import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../util/campus_calendar.dart';
import 'reports_data.dart';

Future<Uint8List> buildReportPdf({
  required ReportSnapshot snapshot,
  required List<QualityIssue> issues,
  required String exportedBy,
  required bool canViewPerAdmin,
  bool stale = false,
  String? staleReason,
}) async {
  final regular = pw.Font.ttf(
    await rootBundle.load('assets/fonts/IBMPlexSans-Regular.ttf'),
  );
  final semiBold = pw.Font.ttf(
    await rootBundle.load('assets/fonts/IBMPlexSans-SemiBold.ttf'),
  );
  final mono = pw.Font.ttf(
    await rootBundle.load('assets/fonts/IBMPlexMono-Regular.ttf'),
  );
  final doc = pw.Document(
    theme: pw.ThemeData.withFont(base: regular, bold: semiBold),
  );
  final scope =
      '${formatDay(campusWallTime(snapshot.scope.from))} - '
      '${formatDay(campusWallTime(snapshot.scope.to))} | '
      '${snapshot.scope.category ?? 'All categories'} | Asia/Manila';

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(32, 30, 32, 34),
      footer: (context) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(scope, style: pw.TextStyle(font: mono, fontSize: 7)),
          pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: pw.TextStyle(font: mono, fontSize: 7),
          ),
        ],
      ),
      build: (context) => [
        pw.Text(
          'SmartReserve Manual Report',
          style: pw.TextStyle(font: semiBold, fontSize: 20),
        ),
        pw.SizedBox(height: 6),
        pw.Text(scope, style: const pw.TextStyle(fontSize: 9)),
        pw.Text(
          'Generated ${formatStamp(campusWallTime(snapshot.generatedAt))} | '
          'Exported by $exportedBy | ${stale ? 'Last verified data' : 'Verified'}',
          style: const pw.TextStyle(fontSize: 9),
        ),
        if (staleReason != null)
          pw.Text(staleReason, style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 18),
        _sectionTitle('Utilisation', semiBold),
        _summaryGrid(snapshot),
        pw.SizedBox(height: 8),
        _table([
          ['Facility', 'Building', 'Booked', 'Available', 'Utilisation'],
          for (final row in snapshot.utilisation)
            [
              row.facilityName,
              row.building,
              row.bookedHours.toStringAsFixed(2),
              row.availableHours.toStringAsFixed(2),
              '${(row.fraction * 100).toStringAsFixed(1)}%',
            ],
        ]),
        pw.SizedBox(height: 16),
        _sectionTitle('Demand', semiBold),
        pw.Text('Legend: 0 none, low, medium, and peak demand by count.'),
        pw.SizedBox(height: 6),
        _table([
          ['Day / time', '07', '09', '11', '13', '15', '17', '19'],
          for (var day = 1; day <= 7; day++)
            [
              _weekday(day),
              for (final hour in const [7, 9, 11, 13, 15, 17, 19])
                '${snapshot.demand.firstWhere((c) => c.day == day && c.hour == hour).count}',
            ],
        ]),
        pw.SizedBox(height: 16),
        _sectionTitle('Approval Performance', semiBold),
        _table([
          ['Metric', 'Value'],
          [
            'Median decision time',
            snapshot.performance.medianHours == null
                ? '-'
                : '${snapshot.performance.medianHours!.toStringAsFixed(1)} h',
          ],
          [
            'Decided within 48 hours',
            snapshot.performance.withinFortyEight == null
                ? '-'
                : '${(snapshot.performance.withinFortyEight! * 100).toStringAsFixed(0)}%',
          ],
          ['Expired without decision', '${snapshot.performance.expired}'],
          ['Declined', '${snapshot.performance.declined}'],
          ['Over capacity', '${snapshot.performance.overCapacity}'],
        ]),
        if (canViewPerAdmin && snapshot.performance.perAdmin.isNotEmpty) ...[
          pw.SizedBox(height: 8),
          _table([
            ['Administrator', 'Decisions', 'Median hours'],
            for (final row in snapshot.performance.perAdmin)
              [
                row.who,
                '${row.decisions}',
                row.median.toStringAsFixed(1),
              ],
          ]),
        ],
        pw.SizedBox(height: 16),
        _sectionTitle('Data Quality', semiBold),
        _table([
          ['Facility', 'Severity', 'Issue', 'Action'],
          for (final issue in issues)
            [
              issue.facility.name,
              issue.severity.label,
              issue.issue,
              issue.actionLabel,
            ],
        ]),
        pw.SizedBox(height: 16),
        _sectionTitle('Metric Definitions', semiBold),
        pw.Text(
          'Utilisation is booked hours divided by available opening hours. '
          'Demand counts booked occurrences in two-hour weekday blocks. '
          'Approval performance measures requester service level from request '
          'creation to decision.',
          style: const pw.TextStyle(fontSize: 9),
        ),
      ],
    ),
  );
  return doc.save();
}

pw.Widget _sectionTitle(String label, pw.Font font) => pw.Padding(
  padding: const pw.EdgeInsets.only(bottom: 6),
  child: pw.Text(label, style: pw.TextStyle(font: font, fontSize: 13)),
);

pw.Widget _summaryGrid(ReportSnapshot snapshot) => pw.Table(
  border: pw.TableBorder.all(color: PdfColors.grey400, width: .5),
  children: [
    pw.TableRow(
      children: [
        _metric('Overall utilisation', '${(snapshot.fraction * 100).toStringAsFixed(1)}%'),
        _metric('Booked hours', snapshot.bookedHours.toStringAsFixed(2)),
        _metric('Available hours', snapshot.availableHours.toStringAsFixed(2)),
      ],
    ),
  ],
);

pw.Widget _metric(String label, String value) => pw.Padding(
  padding: const pw.EdgeInsets.all(6),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(value, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
      pw.Text(label, style: const pw.TextStyle(fontSize: 8)),
    ],
  ),
);

pw.Widget _table(List<List<String>> rows) => pw.TableHelper.fromTextArray(
  data: rows,
  headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8),
  cellStyle: const pw.TextStyle(fontSize: 8),
  cellAlignment: pw.Alignment.centerLeft,
  headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
  border: pw.TableBorder.all(color: PdfColors.grey400, width: .4),
);

String _weekday(int value) => const [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
][value - 1];
