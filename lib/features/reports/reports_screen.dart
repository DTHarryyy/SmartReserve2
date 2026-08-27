import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/facility.dart';
import '../../model/notice.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../util/file_export.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';
import 'reports_data.dart';

import '../../theme/sr_theme.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, this.onFixLocation});

  final void Function(Facility facility)? onFixLocation;

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
    final width = MediaQuery.sizeOf(context).width;
    final narrow = !SR.fitsSplitView(width);
    final stacked = width < SR.tabletMin;
    final selectedCategory = _category == 'All categories' ? null : _category;
    final snapshot = state.reportSnapshot;
    final selectedSnapshot =
        snapshot != null &&
            snapshot.scope.range == _range &&
            snapshot.scope.category == selectedCategory
        ? snapshot
        : null;
    final utilisation = state.usesDemoData
        ? utilisationFor(
            facilities: state.facilities,
            requests: state.requests,
            bookings: state.bookings,
            range: _range,
            category: _category,
          )
        : selectedSnapshot == null
        ? null
        : utilisationFromReport(selectedSnapshot);
    final heatmap = state.usesDemoData
        ? demandFor(state.requests)
        : selectedSnapshot == null
        ? null
        : demandFromReport(selectedSnapshot);
    final performance = state.usesDemoData
        ? performanceFor(state.requests)
        : selectedSnapshot == null
        ? null
        : performanceFromReport(selectedSnapshot);
    final issues = qualityIssuesFor(
      state.facilities
          .where(
            (facility) =>
                selectedCategory == null ||
                facility.category == selectedCategory,
          )
          .toList(),
    );

    return SrScrollView(
      padding: SR.pageInsets(width, top: stacked ? 14 : 20),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _scopeBar(state, selectedSnapshot, utilisation),
              if (state.reportsLoading) const LinearProgressIndicator(),
              if (state.reportsError case final error?)
                _reportError(state, error, stale: selectedSnapshot != null),
              if (state.reportsStale && selectedSnapshot != null)
                _staleNotice(selectedSnapshot),
              if (utilisation != null &&
                  heatmap != null &&
                  performance != null) ...[
                _utilisation(state, utilisation, selectedSnapshot),
                if (narrow) ...[
                  _demand(heatmap, state, selectedSnapshot),
                  _performance(performance),
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _demand(heatmap, state, selectedSnapshot),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: _performance(performance)),
                    ],
                  ),
              ] else if (!state.reportsLoading && state.reportsError == null)
                _initialReportState(),
              _quality(issues),
            ],
          ),
        ),
      ),
    );
  }

  Widget _scopeBar(
    AppState state,
    ReportSnapshot? snapshot,
    List<Utilisation>? utilisation,
  ) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    final rangeFilter = FilterSelect(
      value: _range.label,
      items: [for (final r in ReportRange.values) r.label],
      width: compact ? null : 160,
      semanticLabel: 'Date range',
      onChanged: (v) => setState(() {
        _range = ReportRange.values.firstWhere((r) => r.label == v);
        _drillFacility = null;
        state.refreshReports(
          scope: ReportScope.forRange(
            _range,
            category: _category == 'All categories' ? null : _category,
          ),
        );
      }),
    );
    final categoryFilter = FilterSelect(
      value: _category,
      items: ['All categories', ..._liveCategories(state)],
      width: compact ? null : 210,
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
    );
    final export = SrButton(
      label: 'Export CSV',
      minHeight: compact ? 44 : null,
      onPressed:
          !state.reportsLoading && (state.usesDemoData || snapshot != null)
          ? () => _exportCsv(state, snapshot)
          : null,
    );
    final drillName = _findDrill(utilisation, _drillFacility)?.facilityName;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 13,
        vertical: 11,
      ),
      decoration: BoxDecoration(
        color: context.srColors.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: context.srColors.border),
      ),
      child: compact
          ? Row(
              children: [
                Expanded(child: rangeFilter),
                const SizedBox(width: 6),
                Expanded(child: categoryFilter),
                const SizedBox(width: 6),
                export,
              ],
            )
          : FilterBar(
              count: _scopeSummary(snapshot),
              trailing: [export],
              children: [
                rangeFilter,
                categoryFilter,
                if (drillName != null)
                  FilterPill(
                    label: 'Facility: $drillName',
                    selected: true,
                    onTap: () => setState(() => _drillFacility = null),
                  ),
              ],
            ),
    );
  }

  Utilisation? _findDrill(List<Utilisation>? rows, String? id) {
    if (rows == null || id == null) return null;
    for (final row in rows) {
      if (row.facilityId == id) return row;
    }
    return null;
  }

  String _scopeSummary(ReportSnapshot? snapshot) {
    if (snapshot == null) {
      return '${_range.label.toLowerCase()} · '
          '${_category == 'All categories' ? 'all categories' : _category.toLowerCase()}';
    }
    return '${formatDay(snapshot.scope.from)} – ${formatDay(snapshot.scope.to)} '
        '· updated ${_relativeFreshness(snapshot.generatedAt)}';
  }

  String _relativeFreshness(DateTime generatedAt) {
    final delta = DateTime.now().difference(generatedAt);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) return '${delta.inHours} h ago';
    return '${delta.inDays} d ago';
  }

  List<String> _liveCategories(AppState state) =>
      state.facilities.map((facility) => facility.category).toSet().toList()
        ..sort();

  Future<void> _exportCsv(AppState state, ReportSnapshot? snapshot) async {
    late final String csv;
    if (state.usesDemoData) {
      final rows = utilisationFor(
        facilities: state.facilities,
        requests: state.requests,
        bookings: state.bookings,
        range: _range,
        category: _category,
      );
      csv = [
        'facility,building,category,booked_hours,available_hours,utilisation',
        for (final u in rows)
          '"${u.facilityName.replaceAll('"', '""')}",'
              '"${u.building.replaceAll('"', '""')}",'
              '"${u.category.replaceAll('"', '""')}",'
              '${u.bookedHours.toStringAsFixed(2)},'
              '${u.availableHours.toStringAsFixed(2)},'
              '${(u.fraction * 100).toStringAsFixed(2)}',
      ].join('\n');
    } else {
      if (snapshot == null || state.reportsLoading) return;
      csv = reportCsv(snapshot, exportedBy: state.currentAdmin.name);
    }
    final result = await saveTextFile(
      baseName: 'smartreserve-utilisation-report',
      extension: 'csv',
      contents: csv,
    );
    if (!mounted) return;
    state.showToast(
      result.ok
          ? ToastMessage(
              'Utilisation report saved as CSV to ${result.path}, with the '
              'scope printed in the footer.',
              tone: AdvisoryTone.info,
              action: result.revealSupported
                  ? ToastAction(
                      label: 'Open',
                      onPressed: () => revealInFileExplorer(result.path!),
                    )
                  : null,
            )
          : const ToastMessage(
              "Utilisation report couldn't be saved. Check the destination and try again.",
              tone: AdvisoryTone.block,
            ),
      duration: result.ok && result.revealSupported
          ? const Duration(seconds: 8)
          : const Duration(seconds: 4),
    );
  }

  Widget _reportError(
    AppState state,
    String error, {
    required bool stale,
  }) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: context.srColors.redTint,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: context.srColors.red.withValues(alpha: .25)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            stale ? '$error Showing the last verified result.' : error,
            style: sans(11.5, height: 1.45, color: context.srColors.red),
          ),
        ),
        const SizedBox(width: 10),
        SrButton(
          label: 'Retry',
          dense: true,
          onPressed: state.reportsLoading
              ? null
              : () => state.refreshReports(
                  scope: ReportScope.forRange(
                    _range,
                    category: _category == 'All categories' ? null : _category,
                  ),
                ),
        ),
      ],
    ),
  );

  Widget _staleNotice(ReportSnapshot snapshot) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
    decoration: BoxDecoration(
      color: context.srColors.amberTint,
      borderRadius: BorderRadius.circular(9),
    ),
    child: Text(
      'Last verified ${_reportTimestamp(snapshot.generatedAt)}. These figures may be out of date.',
      style: sans(11.5, color: context.srColors.ink3),
    ),
  );

  Widget _initialReportState() => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
    decoration: BoxDecoration(
      color: context.srColors.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.srColors.border),
    ),
    child: Text(
      'No verified report is available for this scope.',
      textAlign: TextAlign.center,
      style: sans(12, color: context.srColors.muted),
    ),
  );

  String _reportTimestamp(DateTime value) {
    final local = campusWallTime(value);
    final minute = local.minute.toString().padLeft(2, '0');
    return '${formatCampusDate(local)} ${local.hour}:$minute';
  }

  Widget _section({
    required String number,
    required String title,
    required String caption,
    required Widget child,
    String? tooltip,
  }) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: context.srColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.srColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 9,
            runSpacing: 2,
            children: [
              Text(number, style: mono(10, w: 500, color: SR.primary)),
              Text(title, style: sans(13.5, w: 600, tracking: -.01)),
              Tooltip(
                message: tooltip ?? caption,
                child: Text(
                  '$caption ⓘ',
                  style: sans(11, color: context.srColors.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _utilisation(
    AppState state,
    List<Utilisation> rows,
    ReportSnapshot? snapshot,
  ) {
    final totalAvailable = rows.fold<double>(
      0,
      (total, row) => total + row.availableHours,
    );
    final averageFraction =
        snapshot?.fraction ??
        (totalAvailable == 0
            ? 0
            : rows.fold<double>(0, (total, row) => total + row.bookedHours) /
                  totalAvailable);
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
                    formatUtilisationPercent(averageFraction),
                    style: sans(26, w: 600, height: 1, tracking: -.03),
                  ),
                  const SizedBox(height: 5),
                  Text('AVERAGE UTILISATION', style: keyLabel),
                ],
              ),
              Container(width: 1, height: 34, color: context.srColors.hairline),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  rows.isEmpty
                      ? 'No facilities in this category yet — insufficient '
                            'data to report.'
                      : '${worst!.facilityName} is the emptiest at '
                            '${formatUtilisationPercent(worst.fraction)} of its own opening hours. '
                            'Sorted worst first, because the actionable '
                            'insight is the empty room.',
                  style: sans(11.5, height: 1.55, color: context.srColors.ink4),
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
                style: sans(12, color: context.srColors.muted),
              ),
            )
          else
            for (final row in rows)
              _UtilisationRow(
                row: row,
                selected: _drillFacility == row.facilityId,
                onTap: () => setState(
                  () => _drillFacility = _drillFacility == row.facilityId
                      ? null
                      : row.facilityId,
                ),
              ),
          if (_drillFacility != null) _drill(state, snapshot, rows),
        ],
      ),
    );
  }

  Widget _drill(
    AppState state,
    ReportSnapshot? snapshot,
    List<Utilisation> utilisation,
  ) {
    final facility = utilisation.firstWhere(
      (row) => row.facilityId == _drillFacility,
    );
    final liveRows = snapshot == null
        ? const <ReportBookedOccurrence>[]
        : snapshot.bookedOccurrences
              .where((row) => row.facilityId == _drillFacility)
              .toList();
    final demoRows = state.usesDemoData
        ? state.requests
              .where((row) => row.facilityId == _drillFacility)
              .toList()
        : const <ReservationRequest>[];
    final rowCount = state.usesDemoData ? demoRows.length : liveRows.length;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.srColors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${facility.facilityName} · $rowCount '
                  'booked occurrence${rowCount == 1 ? '' : 's'} in range',
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
          if (rowCount == 0)
            Text(
              'No reservations in this period.',
              style: sans(11.5, color: context.srColors.muted),
            )
          else if (!state.usesDemoData)
            for (final row in liveRows) _bookedOccurrenceRow(row)
          else
            for (final r in demoRows)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: context.srColors.dividerSoft),
                  ),
                ),
                child: SR.isCompact(MediaQuery.sizeOf(context).width)
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  r.whenLabel,
                                  style: mono(
                                    11,
                                    w: 500,
                                    color: context.srColors.ink3,
                                  ),
                                ),
                              ),
                              SrPill(
                                label: r.status.label,
                                background: r.status.background,
                                foreground: r.status.foreground,
                                fontSize: 10,
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Text(
                            r.purpose,
                            style: sans(
                              11.5,
                              height: 1.45,
                              color: context.srColors.ink2,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            r.requester,
                            style: sans(11, color: context.srColors.muted),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          SizedBox(
                            width: 150,
                            child: Text(
                              r.whenLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: mono(
                                11,
                                w: 500,
                                color: context.srColors.ink3,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              r.purpose,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: sans(11.5, color: context.srColors.ink2),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            r.requester,
                            style: sans(11, color: context.srColors.muted),
                          ),
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

  Widget _bookedOccurrenceRow(ReportBookedOccurrence row) {
    final starts = campusWallTime(row.startsAt);
    final ends = campusWallTime(row.endsAt);
    final startMinute = starts.minute.toString().padLeft(2, '0');
    final endMinute = ends.minute.toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.srColors.dividerSoft)),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 5,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${formatCampusDate(starts)} · ${starts.hour}:$startMinute–${ends.hour}:$endMinute',
            style: mono(11, w: 500, color: context.srColors.ink3),
          ),
          Text(row.purpose, style: sans(11.5, color: context.srColors.ink2)),
          Text(row.requester, style: sans(11, color: context.srColors.muted)),
          Text(
            '${row.bookedHours.toStringAsFixed(2)} h in range',
            style: mono(10.5, color: context.srColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _demand(
    DemandHeatmap heatmap,
    AppState state,
    ReportSnapshot? snapshot,
  ) {
    final declined =
        snapshot?.performance.declined ??
        state.requests.where((r) => r.status == RequestStatus.declined).length;
    final unmet =
        snapshot?.performance.overCapacity ??
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
                            style: mono(
                              8.5,
                              color: context.srColors.mutedLight,
                            ),
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
                            style: mono(
                              9.5,
                              w: 500,
                              color: context.srColors.muted,
                            ),
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
            style: sans(11, height: 1.55, color: context.srColors.ink4),
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
              valueColor: performance.expired > 0
                  ? context.srColors.red
                  : context.srColors.ink,
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (performance.perAdmin.isEmpty)
          Text(
            'No decisions in this period — insufficient data rather than a '
            'misleading zero.',
            style: sans(11.5, height: 1.55, color: context.srColors.muted),
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
                          Container(height: 7, color: context.srColors.divider),
                          FractionallySizedBox(
                            widthFactor:
                                (admin.decisions /
                                        performance.perAdmin.first.decisions)
                                    .clamp(0.05, 1.0),
                            child: Container(height: 7, color: SR.primary),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${admin.decisions}',
                    style: mono(10.5, color: context.srColors.muted),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 60,
                    child: Text(
                      admin.median < 24
                          ? '${admin.median.round()} h'
                          : '${(admin.median / 24).toStringAsFixed(1)} d',
                      textAlign: TextAlign.right,
                      style: mono(10.5, w: 500, color: context.srColors.ink3),
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 9),
        Text(
          'Figures are limited to your assigned facilities and matching '
          'reservation lane.',
          style: sans(10.5, height: 1.55, color: context.srColors.muted),
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
            style: sans(12, height: 1.6, color: context.srColors.ink4),
          )
        else
          for (final issue in issues)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: context.srColors.dividerSoft),
                ),
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SrPill(
                    label: issue.severity.label,
                    background: switch (issue.severity) {
                      QualitySeverity.blocking => context.srColors.redTint,
                      QualitySeverity.warning => context.srColors.amberTint,
                      QualitySeverity.minor => context.srColors.dividerSoft,
                    },
                    foreground: switch (issue.severity) {
                      QualitySeverity.blocking => context.srColors.red,
                      QualitySeverity.warning => context.srColors.amber,
                      QualitySeverity.minor => context.srColors.ink4,
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
                      style: sans(
                        11.5,
                        height: 1.5,
                        color: context.srColors.ink4,
                      ),
                    ),
                  ),
                  SrButton(
                    label: 'Fix location',
                    dense: true,
                    fontSize: 11,
                    onPressed: widget.onFixLocation == null
                        ? null
                        : () => widget.onFixLocation!(issue.facility),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 12),
        Text(
          'Every row deep-links into the facility with the offending field '
          'loaded, so reporting a problem and fixing it are one step apart.',
          style: sans(11, height: 1.6, color: context.srColors.muted),
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
  Widget build(BuildContext context) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    return Hoverable(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? context.srColors.primaryTint
                : (hovered
                      ? context.srColors.surfaceSubtle
                      : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                row.facilityName,
                                style: sans(12.5, w: 600, height: 1.35),
                              ),
                              Text(
                                row.building,
                                style: sans(
                                  10.5,
                                  color: context.srColors.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          formatUtilisationPercent(row.fraction),
                          style: mono(13, w: 600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 9),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: Stack(
                        children: [
                          Container(height: 9, color: context.srColors.divider),
                          AnimatedFractionallySizedBox(
                            duration: const Duration(milliseconds: 400),
                            curve: SR.easing,
                            widthFactor: row.fraction.clamp(0.0, 1.0),
                            child: Container(
                              height: 9,
                              color: row.fraction < .25
                                  ? SR.orange
                                  : (row.fraction < .6
                                        ? SR.primaryBright
                                        : SR.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${row.bookedHours.round()} of ${row.availableHours.round()} available hours booked',
                      style: mono(10, color: context.srColors.muted),
                    ),
                  ],
                )
              : Row(
                  children: [
                    SizedBox(
                      width: 200,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            row.facilityName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: sans(12, w: 500),
                          ),
                          Text(
                            row.building,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: sans(10, color: context.srColors.muted),
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
                            Container(
                              height: 9,
                              color: context.srColors.divider,
                            ),
                            AnimatedFractionallySizedBox(
                              duration: const Duration(milliseconds: 400),
                              curve: SR.easing,
                              widthFactor: row.fraction.clamp(0.0, 1.0),
                              child: Container(
                                height: 9,
                                color: row.fraction < .25
                                    ? SR.orange
                                    : (row.fraction < .6
                                          ? SR.primaryBright
                                          : SR.primary),
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
                        formatUtilisationPercent(row.fraction),
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
                        style: mono(10.5, color: context.srColors.muted),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
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
              ? context.srColors.divider
              : Color.lerp(context.srColors.primaryTint, SR.primary, intensity),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          count == 0 ? '' : '$count',
          style: mono(
            9.5,
            w: 500,
            color: intensity > .55 ? context.srColors.surface : SR.primaryHover,
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
