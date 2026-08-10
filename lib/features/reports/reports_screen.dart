import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../data/campus_data.dart';
import '../../model/facility.dart';
import '../../model/notice.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/sr_controls.dart';
import 'reports_data.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.onFixLocation});

  final void Function(Facility facility) onFixLocation;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  ReportRange _range = ReportRange.month;
  String _category = 'All categories';
  String? _drillFacility;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 900;
    final stacked = MediaQuery.sizeOf(context).width < SR.tabletMin;

    final localUtilisation = utilisationFor(
      facilities: state.facilities,
      requests: state.requests,
      bookings: state.bookings,
      range: _range,
      category: _category,
    );
    final snapshot = state.reportSnapshot;
    final utilisation = snapshot == null
        ? localUtilisation
        : utilisationFromReport(snapshot, state.facilities);
    final heatmap = snapshot == null
        ? demandFor(state.requests)
        : demandFromReport(snapshot);
    final performance = snapshot == null
        ? performanceFor(state.requests)
        : performanceFromReport(snapshot);
    final issues = qualityIssuesFor(state.facilities);

    return Scrollbar(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          stacked ? 14 : 24,
          stacked ? 14 : 20,
          stacked ? 14 : 24,
          40,
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _scopeBar(state),
                if (state.reportsLoading) const LinearProgressIndicator(),
                if (state.reportsError case final error?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(error, style: sans(11.5, color: SR.red)),
                  ),
                _utilisation(state, utilisation),
                if (narrow) ...[
                  _demand(heatmap, state),
                  _performance(performance),
                ] else
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _demand(heatmap, state)),
                        const SizedBox(width: 12),
                        Expanded(child: _performance(performance)),
                      ],
                    ),
                  ),
                _quality(issues),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _scopeBar(AppState state) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    decoration: BoxDecoration(
      color: SR.surface,
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: SR.border),
    ),
    child: FilterBar(
      count:
          '${_range.label.toLowerCase()} · '
          '${_category == 'All categories' ? 'all categories' : _category.toLowerCase()}',
      trailing: [
        SrButton(label: 'Export CSV', onPressed: () => _exportCsv(state)),
      ],
      children: [
        FilterSelect(
          value: _range.label,
          items: [for (final r in ReportRange.values) r.label],
          semanticLabel: 'Date range',
          onChanged: (v) => setState(() {
            _range = ReportRange.values.firstWhere((r) => r.label == v);
            state.refreshReports(
              scope: ReportScope.forRange(
                _range,
                category: _category == 'All categories' ? null : _category,
              ),
            );
          }),
        ),
        FilterSelect(
          value: _category,
          items: ['All categories', ...categories],
          semanticLabel: 'Category',
          onChanged: (v) => setState(() {
            _category = v;
            _drillFacility = null;
            state.refreshReports(
              scope: ReportScope.forRange(
                _range,
                category: _category == 'All categories' ? null : _category,
              ),
            );
          }),
        ),
      ],
    ),
  );

  Future<void> _exportCsv(AppState state) async {
    final rows = utilisationFor(
      facilities: state.facilities,
      requests: state.requests,
      bookings: state.bookings,
      range: _range,
      category: _category,
    );
    final csv = [
      'facility,building,category,booked_hours,available_hours,utilisation',
      for (final u in rows)
        '"${u.facility.name}","${u.facility.building}",'
            '"${u.facility.category}",${u.bookedHours.toStringAsFixed(1)},'
            '${u.availableHours.toStringAsFixed(1)},${u.percent}%',
      '# ${_range.label} · $_category · exported by ${state.currentAdmin.name}',
    ].join('\n');
    await FileSaver.instance.saveAs(
      name: 'smartreserve-utilisation-report',
      bytes: Uint8List.fromList(utf8.encode(csv)),
      fileExtension: 'csv',
      mimeType: MimeType.text,
    );
    state.showToast(
      const ToastMessage(
        'Utilisation report saved as CSV, with the scope printed in the footer.',
        tone: AdvisoryTone.info,
      ),
    );
  }

  Widget _section({
    required String number,
    required String title,
    required String caption,
    required Widget child,
    String? tooltip,
  }) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: SR.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SR.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 9,
          runSpacing: 2,
          children: [
            Text(number, style: mono(10, w: 500, color: SR.blue)),
            Text(title, style: sans(13.5, w: 600, tracking: -.01)),
            Tooltip(
              message: tooltip ?? caption,
              child: Text('$caption ⓘ', style: sans(11, color: SR.muted)),
            ),
          ],
        ),
        const SizedBox(height: 14),
        child,
      ],
    ),
  );

  Widget _utilisation(AppState state, List<Utilisation> rows) {
    final average = rows.isEmpty
        ? 0
        : (rows.map((u) => u.fraction).reduce((a, b) => a + b) /
                  rows.length *
                  100)
              .round();
    final worst = rows.isEmpty ? null : rows.first;

    return _section(
      number: '01',
      title: 'Utilisation',
      caption: 'Which rooms are standing empty',
      tooltip: 'Booked hours divided by operating hours in the selected range.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$average%',
                    style: sans(26, w: 600, height: 1, tracking: -.03),
                  ),
                  const SizedBox(height: 5),
                  Text('AVERAGE UTILISATION', style: keyLabel),
                ],
              ),
              Container(width: 1, height: 34, color: SR.hairline),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  rows.isEmpty
                      ? 'No facilities in this category yet — insufficient '
                            'data to report.'
                      : '${worst!.facility.name} is the emptiest at '
                            '${worst.percent}% of its own opening hours. '
                            'Sorted worst first, because the actionable '
                            'insight is the empty room.',
                  style: sans(11.5, height: 1.55, color: SR.ink4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 26),
              child: Text(
                'No facilities in this category yet — insufficient data to '
                'report.',
                textAlign: TextAlign.center,
                style: sans(12, color: SR.muted),
              ),
            )
          else
            for (final row in rows)
              _UtilisationRow(
                row: row,
                selected: _drillFacility == row.facility.name,
                onTap: () => setState(
                  () => _drillFacility = _drillFacility == row.facility.name
                      ? null
                      : row.facility.name,
                ),
              ),
          if (_drillFacility != null) _drill(state),
        ],
      ),
    );
  }

  Widget _drill(AppState state) {
    final rows = [
      for (final r in state.requests)
        if (r.facility == _drillFacility) r,
    ];
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.only(top: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: SR.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$_drillFacility · ${rows.length} '
                  'request${rows.length == 1 ? '' : 's'} on record',
                  style: sans(12, w: 600),
                ),
              ),
              SrButton(
                label: 'Clear',
                dense: true,
                fontSize: 11,
                onPressed: () => setState(() => _drillFacility = null),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            Text(
              'No reservations in this period.',
              style: sans(11.5, color: SR.muted),
            )
          else
            for (final r in rows)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: SR.dividerSoft)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 150,
                      child: Text(
                        r.whenLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono(11, w: 500, color: SR.ink3),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        r.purpose,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sans(11.5, color: SR.ink2),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(r.requester, style: sans(11, color: SR.muted)),
                    const SizedBox(width: 10),
                    SrPill(
                      label: r.status.label,
                      background: r.status.background,
                      foreground: r.status.foreground,
                      fontSize: 10,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _demand(DemandHeatmap heatmap, AppState state) {
    final declined =
        state.reportSnapshot?.performance.declined ??
        state.requests.where((r) => r.status == RequestStatus.declined).length;
    final unmet =
        state.reportSnapshot?.performance.overCapacity ??
        state.requests.where((r) => r.heads > r.capacity).length;

    return _section(
      number: '02',
      title: 'Demand',
      caption: 'Where demand exceeds supply',
      tooltip: 'Requests received per weekday and two-hour block.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Stat(value: '$declined', label: 'DECLINED'),
              const SizedBox(width: 18),
              _Stat(value: '$unmet', label: 'OVER CAPACITY'),
            ],
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 34, bottom: 3),
                  child: Row(
                    children: [
                      for (final hour in heatmap.hours)
                        SizedBox(
                          width: 30,
                          child: Text(
                            hour,
                            textAlign: TextAlign.center,
                            style: mono(8.5, color: SR.mutedLight),
                          ),
                        ),
                    ],
                  ),
                ),
                for (var day = 0; day < heatmap.days.length; day++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 34,
                          child: Text(
                            heatmap.days[day],
                            style: mono(9.5, w: 500, color: SR.muted),
                          ),
                        ),
                        for (
                          var block = 0;
                          block < heatmap.cells[day].length;
                          block++
                        )
                          _HeatCell(
                            count: heatmap.cells[day][block],
                            peak: heatmap.peak,
                            title:
                                '${heatmap.days[day]} '
                                '${heatmap.hours[block]}:00 — '
                                '${heatmap.cells[day][block]} requests',
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 11),
          Text(
            heatmap.peak == 0
                ? 'No requests in this period — no declines to report either.'
                : 'Peak is ${heatmap.peak} concurrent requests in one block. '
                      'That is the case for converting space, and it exports '
                      'as-is for a budget memo.',
            style: sans(11, height: 1.55, color: SR.ink4),
          ),
        ],
      ),
    );
  }

  Widget _performance(ApprovalPerformance performance) => _section(
    number: '03',
    title: 'Approval performance',
    caption: 'Service level to requesters',
    tooltip:
        'Measured from submission to decision. Framed as service level, not '
        'staff surveillance.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SrCellGrid(
          columns: 3,
          children: [
            SrKeyCell(label: 'MEDIAN DECISION', value: performance.medianLabel),
            SrKeyCell(
              label: 'WITHIN 48 H',
              value: performance.medianHours == null
                  ? '—'
                  : '${(performance.withinFortyEight * 100).round()}%',
            ),
            SrKeyCell(
              label: 'EXPIRED',
              value: '${performance.expired}',
              valueColor: performance.expired > 0 ? SR.red : SR.ink,
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (performance.perAdmin.isEmpty)
          Text(
            'No decisions in this period — insufficient data rather than a '
            'misleading zero.',
            style: sans(11.5, height: 1.55, color: SR.muted),
          )
        else
          for (final admin in performance.perAdmin)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: Text(
                      admin.who,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(11.5, w: 500),
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Stack(
                        children: [
                          Container(height: 7, color: SR.divider),
                          FractionallySizedBox(
                            widthFactor:
                                (admin.decisions /
                                        performance.perAdmin.first.decisions)
                                    .clamp(0.05, 1.0),
                            child: Container(height: 7, color: SR.blue),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${admin.decisions}',
                    style: mono(10.5, color: SR.muted),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 60,
                    child: Text(
                      admin.median < 24
                          ? '${admin.median.round()} h'
                          : '${(admin.median / 24).toStringAsFixed(1)} d',
                      textAlign: TextAlign.right,
                      style: mono(10.5, w: 500, color: SR.ink3),
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 9),
        Text(
          'Per-admin figures are visible to the registrar role only.',
          style: sans(10.5, height: 1.55, color: SR.muted),
        ),
      ],
    ),
  );

  Widget _quality(List<QualityIssue> issues) => _section(
    number: '04',
    title: 'Data quality',
    caption: 'Pins and records that break wayfinding',
    tooltip:
        'Every row deep-links into the facility with the offending field '
        'loaded.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (issues.isEmpty)
          Text(
            'Every facility has a pin inside the boundary, close to its '
            'building, with photos. Nothing to fix.',
            style: sans(12, height: 1.6, color: SR.ink4),
          )
        else
          for (final issue in issues)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: SR.dividerSoft)),
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SrPill(
                    label: issue.severity.label,
                    background: switch (issue.severity) {
                      QualitySeverity.blocking => SR.redTint,
                      QualitySeverity.warning => SR.amberTint,
                      QualitySeverity.minor => SR.dividerSoft,
                    },
                    foreground: switch (issue.severity) {
                      QualitySeverity.blocking => SR.red,
                      QualitySeverity.warning => SR.amber,
                      QualitySeverity.minor => SR.ink4,
                    },
                    fontSize: 10,
                  ),
                  SizedBox(
                    width: 190,
                    child: Text(
                      issue.facility.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(12, w: 500),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Text(
                      issue.issue,
                      style: sans(11.5, height: 1.5, color: SR.ink4),
                    ),
                  ),
                  SrButton(
                    label: 'Fix location',
                    dense: true,
                    fontSize: 11,
                    onPressed: () => widget.onFixLocation(issue.facility),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 12),
        Text(
          'Every row deep-links into the facility with the offending field '
          'loaded, so reporting a problem and fixing it are one step apart.',
          style: sans(11, height: 1.6, color: SR.muted),
        ),
      ],
    ),
  );
}

class _UtilisationRow extends StatelessWidget {
  const _UtilisationRow({
    required this.row,
    required this.selected,
    required this.onTap,
  });

  final Utilisation row;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Hoverable(
    builder: (context, hovered) => GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? SR.blueTint
              : (hovered ? SR.surfaceSubtle : Colors.transparent),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 200,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    row.facility.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sans(12, w: 500),
                  ),
                  Text(
                    row.facility.building,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sans(10, color: SR.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: Stack(
                  children: [
                    Container(height: 9, color: SR.divider),
                    AnimatedFractionallySizedBox(
                      duration: const Duration(milliseconds: 400),
                      curve: SR.easing,
                      widthFactor: row.fraction.clamp(0.0, 1.0),
                      child: Container(
                        height: 9,
                        color: row.fraction < .25
                            ? SR.orange
                            : (row.fraction < .6 ? SR.blueBright : SR.blue),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 44,
              child: Text(
                '${row.percent}%',
                textAlign: TextAlign.right,
                style: mono(12, w: 500),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 86,
              child: Text(
                '${row.bookedHours.round()} / ${row.availableHours.round()} h',
                textAlign: TextAlign.right,
                style: mono(10.5, color: SR.muted),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _HeatCell extends StatelessWidget {
  const _HeatCell({
    required this.count,
    required this.peak,
    required this.title,
  });

  final int count;
  final int peak;
  final String title;

  @override
  Widget build(BuildContext context) {
    final intensity = peak == 0 ? 0.0 : count / peak;
    return Tooltip(
      message: title,
      child: Container(
        width: 30,
        height: 26,
        margin: const EdgeInsets.only(right: 3),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: count == 0
              ? SR.divider
              : Color.lerp(SR.blueTint, SR.blue, intensity),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          count == 0 ? '' : '$count',
          style: mono(
            9.5,
            w: 500,
            color: intensity > .55 ? SR.surface : SR.blueDark,
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(value, style: sans(22, w: 600, height: 1, tracking: -.02)),
      const SizedBox(height: 5),
      Text(label, style: keyLabel),
    ],
  );
}
