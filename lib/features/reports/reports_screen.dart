import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/notice.dart';
import '../../model/payment.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../util/file_export.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';
import 'report_export.dart';
import 'report_pdf.dart';
import 'report_scope_url.dart';
import 'reports_data.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, this.onResolveQualityIssue});

  final void Function(QualityIssue issue)? onResolveQualityIssue;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  ReportRange _range = ReportRange.month;
  String _category = 'All categories';
  String? _drillFacility;
  _DemandSelection? _demandSelection;
  var _syncedInitialScope = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_syncedInitialScope) return;
    _syncedInitialScope = true;
    final state = AppScope.read(context);
    final scope = state.reportScope;
    if (scope != null) {
      _range = scope.range;
      _category = scope.category ?? 'All categories';
    }
    final initialFacility = state.initialReportFacilityId;
    if (initialFacility != null &&
        state.facilities.any((facility) => facility.id == initialFacility)) {
      _drillFacility = initialFacility;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final split = SR.fitsSplitView(width);
    final stacked = width < SR.tabletMin;
    final selectedCategory = _selectedCategory;
    final loadState = state.reportState;
    final stateSnapshot = loadState.snapshot;
    final snapshot = (stateSnapshot?.hasSameSelection(_scope()) ?? false)
        ? stateSnapshot
        : null;
    final stale = loadState is ReportStale && snapshot != null;
    final utilisation = state.usesDemoData
        ? utilisationFor(
            facilities: state.facilities,
            requests: state.requests,
            bookings: state.bookings,
            range: _range,
            category: _category,
          )
        : snapshot == null
        ? null
        : utilisationFromReport(snapshot);
    final heatmap = state.usesDemoData
        ? demandFor(state.requests)
        : snapshot == null
        ? null
        : demandFromReport(snapshot);
    final performance = state.usesDemoData
        ? performanceFor(state.requests)
        : snapshot == null
        ? null
        : performanceFromReport(snapshot);
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _scopeCard(state, snapshot, issues),
          if (loadState is ReportFailed) _failureCard(state, loadState.failure),
          if (loadState is ReportStale && snapshot != null)
            _staleCard(state, loadState),
          if (!state.usesDemoData &&
              loadState is ReportInitialLoading &&
              snapshot == null)
            _skeletons(split),
          if (utilisation != null &&
              heatmap != null &&
              performance != null) ...[
            _utilisation(state, utilisation, snapshot, stale: stale),
            if (snapshot != null && state.isExternalAdmin)
              _revenue(state, snapshot, stale: stale),
            if (split)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _demand(state, heatmap, snapshot, stale: stale),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _performance(
                      state,
                      performance,
                      snapshot: snapshot,
                      canViewPerAdmin: state.isInternalAdmin,
                      stale: stale,
                    ),
                  ),
                ],
              )
            else ...[
              _demand(state, heatmap, snapshot, stale: stale),
              _performance(
                state,
                performance,
                snapshot: snapshot,
                canViewPerAdmin: state.isInternalAdmin,
                stale: stale,
              ),
            ],
          ],
          if (loadState is ReportFailed) _qualityDivider(),
          _quality(state, issues),
        ],
      ),
    );
  }

  String? get _selectedCategory =>
      _category == 'All categories' ? null : _category;

  ReportScope _scope() =>
      ReportScope.forRange(_range, category: _selectedCategory);

  void _changeRange(AppState state, String label) {
    final next = ReportRange.values.firstWhere((range) => range.label == label);
    if (_range == next) return;
    setState(() {
      _range = next;
      _drillFacility = null;
      _demandSelection = null;
    });
    _refresh(state);
    _replaceLink();
  }

  void _changeCategory(AppState state, String label) {
    if (_category == label) return;
    setState(() {
      _category = label;
      _drillFacility = null;
      _demandSelection = null;
    });
    _refresh(state);
    _replaceLink();
  }

  void _refresh(AppState state) {
    final next = _scope();
    if (state.reportState.isLoading &&
        (state.reportScope?.hasSameSelection(next) ?? false)) {
      return;
    }
    state.refreshReports(scope: next);
  }

  void _selectFacility(String? id) {
    setState(() => _drillFacility = _drillFacility == id ? null : id);
    _replaceLink();
  }

  void _replaceLink() {
    if (!canCopyReportLink) return;
    replaceReportLink(
      ReportLinkSelection(
        range: _range,
        category: _selectedCategory,
        facilityId: _drillFacility,
      ),
    );
  }

  Widget _scopeCard(
    AppState state,
    ReportSnapshot? snapshot,
    List<QualityIssue> issues,
  ) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    final canExport = snapshot != null;
    final freshness = switch (state.reportState) {
      ReportRefreshing() => 'Refreshing latest data...',
      ReportStale(:final snapshot) =>
        'Last verified ${_reportTimestamp(snapshot.generatedAt)}',
      ReportReady(:final snapshot) =>
        'Updated ${_relativeFreshness(snapshot.generatedAt)}',
      _ => 'Waiting for a verified report',
    };
    final filters = [
      _labeledControl(
        'Reporting period',
        FilterSelect(
          value: _range.label,
          items: [for (final r in ReportRange.values) r.label],
          width: compact ? null : 180,
          semanticLabel: 'Reporting period',
          onChanged: (value) => _changeRange(state, value),
        ),
      ),
      _labeledControl(
        'Facility category',
        FilterSelect(
          value: _category,
          items: ['All categories', ..._liveCategories(state)],
          width: compact ? null : 230,
          semanticLabel: 'Facility category',
          onChanged: (value) => _changeCategory(state, value),
        ),
      ),
    ];
    final actions = [
      SrButton(
        label: 'Refresh',
        icon: const Icon(Icons.refresh_rounded, size: SR.iconSm),
        dense: true,
        onPressed: state.reportState.isLoading ? null : () => _refresh(state),
      ),
      Tooltip(
        message: canExport
            ? 'Download the verified report'
            : 'A verified report is required before export.',
        child: PopupMenuButton<String>(
          enabled: canExport,
          tooltip: 'Export report',
          onSelected: (value) => _export(state, snapshot, issues, value),
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'csv', child: Text('Download CSV')),
            PopupMenuItem(value: 'pdf', child: Text('Download PDF')),
          ],
          child: IgnorePointer(
            child: SrButton(
              label: 'Export',
              icon: const Icon(Icons.download_rounded, size: SR.iconSm),
              trailing: const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
              dense: true,
              onPressed: canExport ? () {} : null,
            ),
          ),
        ),
      ),
      if (canCopyReportLink)
        SrButton(
          label: 'Copy report link',
          icon: const Icon(Icons.link_rounded, size: SR.iconSm),
          dense: true,
          onPressed: () => _copyReportLink(state),
        ),
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: EdgeInsets.all(compact ? 13 : 16),
      decoration: BoxDecoration(
        color: context.srColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.srColors.border),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final filter in filters) ...[
                  filter,
                  const SizedBox(height: 10),
                ],
                _scopeSummary(snapshot, freshness),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final filter in filters) ...[
                  filter,
                  const SizedBox(width: 10),
                ],
                Expanded(child: _scopeSummary(snapshot, freshness)),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ),
    );
  }

  Widget _labeledControl(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: keyLabel),
      const SizedBox(height: 5),
      child,
    ],
  );

  Widget _scopeSummary(ReportSnapshot? snapshot, String freshness) {
    final scope = snapshot?.scope ?? _scope();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${formatDay(campusWallTime(scope.from))} - ${formatDay(campusWallTime(scope.to))}',
          style: sans(12.5, w: 600),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 9,
          runSpacing: 3,
          children: [
            Text(scope.category ?? 'All categories', style: mono(10.5)),
            Text('Asia/Manila', style: mono(10.5)),
            Text(freshness, style: sans(11, color: context.srColors.muted)),
          ],
        ),
      ],
    );
  }

  Widget _failureCard(AppState state, ReportFailure failure) => _alertCard(
    tone: AdvisoryTone.block,
    title: 'Report data could not be verified',
    body:
        '${failure.explanation}\nScope: ${_scopeLabel(_scope())}\nSupport reference: ${failure.supportReference}',
    actions: [
      SrButton(
        label: 'Copy details',
        dense: true,
        onPressed: () => _copyFailureDetails(state, failure),
      ),
      SrButton(
        label: 'Retry',
        dense: true,
        kind: SrButtonKind.primary,
        onPressed: state.reportState.isLoading ? null : () => _refresh(state),
      ),
    ],
  );

  Widget _staleCard(AppState state, ReportStale stale) => _alertCard(
    tone: AdvisoryTone.warn,
    title:
        'Showing the last verified report from ${_reportTimestamp(stale.snapshot.generatedAt)}.',
    body:
        '${stale.failure.explanation}\nSupport reference: ${stale.failure.supportReference}',
    actions: [
      SrButton(
        label: 'Retry',
        dense: true,
        kind: SrButtonKind.caution,
        onPressed: state.reportState.isLoading ? null : () => _refresh(state),
      ),
    ],
  );

  Widget _alertCard({
    required AdvisoryTone tone,
    required String title,
    required String body,
    required List<Widget> actions,
  }) {
    final colors = context.srColors;
    final background = switch (tone) {
      AdvisoryTone.block => colors.redTint,
      AdvisoryTone.warn => colors.amberTint,
      AdvisoryTone.good => colors.greenTint,
      AdvisoryTone.info => colors.primaryTint,
    };
    final foreground = switch (tone) {
      AdvisoryTone.block => colors.red,
      AdvisoryTone.warn => colors.amber,
      AdvisoryTone.good => colors.greenDark,
      AdvisoryTone.info => colors.primaryDeep,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: foreground.withValues(alpha: .28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: sans(13, w: 600, color: foreground)),
          const SizedBox(height: 6),
          Text(body, style: sans(11.5, height: 1.55, color: colors.ink3)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ),
    );
  }

  Widget _skeletons(bool split) {
    final cards = [
      _skeletonSection('Utilisation'),
      _skeletonSection('Demand'),
      _skeletonSection('Approval performance'),
    ];
    return Column(
      children: [
        cards.first,
        if (split)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: cards[1]),
              const SizedBox(width: 12),
              Expanded(child: cards[2]),
            ],
          )
        else
          ...cards.skip(1),
      ],
    );
  }

  Widget _skeletonSection(String title) => _section(
    number: '',
    title: title,
    caption: 'Loading verified report data',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _skeletonLine(width: 220, height: 24),
        const SizedBox(height: 16),
        for (var i = 0; i < 5; i++) ...[
          _skeletonLine(height: 14),
          const SizedBox(height: 9),
        ],
      ],
    ),
  );

  Widget _skeletonLine({double? width, double height = 12}) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      width: width ?? double.infinity,
      height: height,
      decoration: BoxDecoration(
        color: context.srColors.dividerSoft,
        borderRadius: BorderRadius.circular(4),
      ),
    ),
  );

  Widget _section({
    required String number,
    required String title,
    required String caption,
    required Widget child,
    bool stale = false,
    String? tooltip,
  }) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: context.srColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.srColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 9,
            runSpacing: 4,
            children: [
              if (number.isNotEmpty)
                Text(number, style: mono(10, w: 500, color: SR.primary)),
              Text(title, style: sans(13.5, w: 600)),
              Tooltip(
                message: tooltip ?? caption,
                child: Text(
                  caption,
                  style: sans(11, color: context.srColors.muted),
                ),
              ),
              if (stale)
                SrPill(
                  label: 'Last verified data',
                  background: context.srColors.amberTint,
                  foreground: context.srColors.amber,
                  fontSize: 10,
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
    ReportSnapshot? snapshot, {
    required bool stale,
  }) {
    final totalBooked =
        snapshot?.bookedHours ??
        rows.fold<double>(0, (total, row) => total + row.bookedHours);
    final totalAvailable =
        snapshot?.availableHours ??
        rows.fold<double>(0, (total, row) => total + row.availableHours);
    final fraction =
        snapshot?.fraction ??
        (totalAvailable == 0 ? 0.0 : totalBooked / totalAvailable);
    return _section(
      number: '01',
      title: 'Utilisation',
      caption: 'Worst-first facility utilisation',
      stale: stale,
      tooltip: 'Booked hours divided by available opening hours.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SrCellGrid(
            columns: 3,
            children: [
              SrKeyCell(
                label: 'WEIGHTED UTILISATION',
                value: formatUtilisationPercent(fraction),
              ),
              SrKeyCell(
                label: 'BOOKED HOURS',
                value: totalBooked.toStringAsFixed(2),
                valueMono: true,
              ),
              SrKeyCell(
                label: 'AVAILABLE HOURS',
                value: totalAvailable.toStringAsFixed(2),
                valueMono: true,
              ),
            ],
          ),
          if (snapshot != null) ...[
            const SizedBox(height: 10),
            _sectionExportButton(
              () => _exportSectionText(
                state,
                baseName: 'smartreserve-utilisation-report',
                label: 'Utilisation CSV',
                contents: utilisationCsv(
                  snapshot,
                  exportedBy: state.currentAdmin.name,
                  stale: state.reportState is ReportStale,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          if (rows.isEmpty)
            _empty('No available facilities are in this report scope.')
          else
            for (final row in rows)
              _UtilisationRow(
                row: row,
                selected: _drillFacility == row.facilityId,
                onTap: () => _selectFacility(row.facilityId),
              ),
          if (_drillFacility != null &&
              rows.any((row) => row.facilityId == _drillFacility))
            _drillDown(snapshot, rows),
        ],
      ),
    );
  }

  Widget _drillDown(ReportSnapshot? snapshot, List<Utilisation> utilisation) {
    final facility = utilisation.firstWhere(
      (row) => row.facilityId == _drillFacility,
    );
    final rows = snapshot == null
        ? const <ReportBookedOccurrence>[]
        : snapshot.bookedOccurrences
              .where((row) => row.facilityId == _drillFacility)
              .toList();
    return Container(
      margin: const EdgeInsets.only(top: 14),
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
                  '${facility.facilityName} booked occurrences',
                  style: sans(12, w: 600),
                ),
              ),
              SrButton(
                label: 'Clear facility filter',
                dense: true,
                fontSize: 11,
                onPressed: () => _selectFacility(null),
              ),
            ],
          ),
          const SizedBox(height: 9),
          if (rows.isEmpty)
            _empty('No booked requests occurred for this facility in scope.')
          else
            _occurrenceTable(rows),
        ],
      ),
    );
  }

  Widget _revenue(
    AppState state,
    ReportSnapshot snapshot, {
    required bool stale,
  }) {
    final revenue = snapshot.revenue;
    return _section(
      number: '02',
      title: 'Revenue',
      caption: 'Verified cash basis',
      stale: stale,
      tooltip:
          'Gross collections use verified payment time. Refunds use refund time when present.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SrCellGrid(
            columns: 4,
            children: [
              SrKeyCell(
                label: 'GROSS COLLECTIONS',
                value: pesoFromCentavos(revenue.grossVerifiedCentavos),
              ),
              SrKeyCell(
                label: 'REFUNDS',
                value: pesoFromCentavos(revenue.refundsCentavos),
              ),
              SrKeyCell(
                label: 'NET REVENUE',
                value: pesoFromCentavos(revenue.netRevenueCentavos),
              ),
              SrKeyCell(
                label: 'OUTSTANDING',
                value: pesoFromCentavos(revenue.outstandingCentavos),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _sectionExportButton(
            () => _exportSectionText(
              state,
              baseName: 'smartreserve-financial-report',
              label: 'Financial CSV',
              contents: revenueCsv(
                snapshot,
                exportedBy: state.currentAdmin.name,
                canViewRevenue: state.isExternalAdmin,
                stale: state.reportState is ReportStale,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (snapshot.monthlyStatistics.isEmpty)
            _empty('No monthly statistics are available for this scope.')
          else
            for (final row in snapshot.monthlyStatistics)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        _monthLabel(row.monthStart),
                        style: mono(11, w: 600),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${row.submittedReservations} submitted · '
                        '${row.completedOccurrences} completed · '
                        '${formatUtilisationPercent(row.utilisationFraction)} used',
                        style: SrType.bodySm(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      pesoFromCentavos(row.netRevenueCentavos),
                      style: mono(11, w: 600),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _occurrenceTable(List<ReportBookedOccurrence> rows) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!compact)
          _tableHeader([
            'Date/time',
            'Purpose',
            'Requester',
            'Status',
            'Booked hours',
          ]),
        for (final row in rows) _occurrenceRow(row, compact: compact),
      ],
    );
  }

  Widget _occurrenceRow(ReportBookedOccurrence row, {required bool compact}) {
    final starts = campusWallTime(row.startsAt);
    final ends = campusWallTime(row.endsAt);
    final values = [
      '${formatCampusDate(starts)} ${_clock(starts)}-${_clock(ends)}',
      row.purpose,
      row.requester,
      row.requestStatus,
      '${row.bookedHours.toStringAsFixed(2)} h',
    ];
    return _dataRow(values, compact: compact);
  }

  Widget _demand(
    AppState state,
    DemandHeatmap heatmap,
    ReportSnapshot? snapshot, {
    required bool stale,
  }) {
    final rows =
        snapshot?.bookedOccurrences ?? const <ReportBookedOccurrence>[];
    final filtered = _demandSelection == null
        ? rows
        : rows.where(_demandSelection!.matches).toList();
    return _section(
      number: '02',
      title: 'Demand',
      caption: 'Booked demand by weekday and time block',
      stale: stale,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (snapshot != null) ...[
            _sectionExportButton(
              () => _exportSectionText(
                state,
                baseName: 'smartreserve-demand-report',
                label: 'Demand CSV',
                contents: demandCsv(
                  snapshot,
                  exportedBy: state.currentAdmin.name,
                  stale: state.reportState is ReportStale,
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          _legend(heatmap.peak),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 58, bottom: 4),
                  child: Row(
                    children: [
                      for (final hour in heatmap.hours)
                        SizedBox(
                          width: 44,
                          child: Text(
                            formatHour12(int.parse(hour)),
                            textAlign: TextAlign.center,
                            style: mono(9, color: context.srColors.muted),
                          ),
                        ),
                    ],
                  ),
                ),
                for (var day = 0; day < heatmap.days.length; day++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 58,
                          child: Text(
                            heatmap.days[day],
                            style: mono(9.5, w: 500),
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
                            selected:
                                _demandSelection?.day == day + 1 &&
                                _demandSelection?.hour ==
                                    int.parse(heatmap.hours[block]),
                            label:
                                '${_weekday(day + 1)}, '
                                '${formatHour12(int.parse(heatmap.hours[block]))}-'
                                '${formatHour12(int.parse(heatmap.hours[block]) + 2)}, '
                                '${heatmap.cells[day][block]} booked requests',
                            onTap: () => setState(() {
                              final next = _DemandSelection(
                                day + 1,
                                int.parse(heatmap.hours[block]),
                              );
                              _demandSelection = _demandSelection == next
                                  ? null
                                  : next;
                            }),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (heatmap.peak == 0)
            _empty('No booked requests occurred in this scope.')
          else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    _demandSelection == null
                        ? 'Supporting booked-occurrence list'
                        : '${_weekday(_demandSelection!.day)} '
                              '${formatHour12(_demandSelection!.hour)}-'
                              '${formatHour12(_demandSelection!.hour + 2)}',
                    style: sans(12, w: 600),
                  ),
                ),
                if (_demandSelection != null)
                  SrButton(
                    label: 'Clear time filter',
                    dense: true,
                    fontSize: 11,
                    onPressed: () => setState(() => _demandSelection = null),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (filtered.isEmpty)
              _empty('No booked requests occurred in this time block.')
            else
              for (final row in filtered.take(8)) _bookedLine(row),
          ],
        ],
      ),
    );
  }

  Widget _legend(int peak) {
    final labels = peak == 0
        ? const ['Zero', 'Low', 'Medium', 'Peak']
        : ['0', 'Low', 'Medium', '$peak peak'];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < 4; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 18,
                height: 10,
                decoration: BoxDecoration(
                  color: i == 0
                      ? context.srColors.divider
                      : Color.lerp(
                          context.srColors.primaryTint,
                          SR.primary,
                          i / 3,
                        ),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 5),
              Text(labels[i], style: sans(10.5, color: context.srColors.muted)),
            ],
          ),
      ],
    );
  }

  Widget _bookedLine(ReportBookedOccurrence row) {
    final starts = campusWallTime(row.startsAt);
    final ends = campusWallTime(row.endsAt);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.srColors.dividerSoft)),
      ),
      child: Text(
        '${formatCampusDate(starts)} ${_clock(starts)}-${_clock(ends)} · ${row.purpose} · ${row.requester}',
        style: sans(11.2, height: 1.45, color: context.srColors.ink3),
      ),
    );
  }

  Widget _performance(
    AppState state,
    ApprovalPerformance performance, {
    required ReportSnapshot? snapshot,
    required bool canViewPerAdmin,
    required bool stale,
  }) => _section(
    number: '03',
    title: 'Approval performance',
    caption: 'Requester service level',
    tooltip:
        'Measured from request submission to decision. This is a service-level view.',
    stale: stale,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (snapshot != null) ...[
          _sectionExportButton(
            () => _exportSectionText(
              state,
              baseName: 'smartreserve-approval-performance-report',
              label: 'Approval performance CSV',
              contents: approvalPerformanceCsv(
                snapshot,
                exportedBy: state.currentAdmin.name,
                canViewPerAdmin: canViewPerAdmin,
                stale: stale,
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
        SrCellGrid(
          columns: 3,
          children: [
            SrKeyCell(label: 'MEDIAN DECISION', value: performance.medianLabel),
            SrKeyCell(
              label: 'WITHIN 48 H',
              value: performance.withinFortyEight == null
                  ? '-'
                  : '${(performance.withinFortyEight! * 100).round()}%',
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
        const SizedBox(height: 12),
        if (performance.medianHours == null)
          Text(
            'No decisions in this period. Percentages are left blank instead of shown as zero.',
            style: sans(11.5, height: 1.55, color: context.srColors.muted),
          )
        else if (!canViewPerAdmin)
          Text(
            'Named administrator data is hidden for external administrators. These are lane-scoped aggregate service metrics.',
            style: sans(11.5, height: 1.55, color: context.srColors.muted),
          )
        else if (performance.perAdmin.isNotEmpty) ...[
          Text('Internal administrator breakdown', style: sans(12, w: 600)),
          const SizedBox(height: 8),
          for (final admin in performance.perAdmin)
            _adminRow(performance, admin),
        ],
      ],
    ),
  );

  Widget _adminRow(
    ApprovalPerformance performance,
    ({String? id, String who, int decisions, double median}) admin,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        SizedBox(
          width: 130,
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
                      (admin.decisions / performance.perAdmin.first.decisions)
                          .clamp(0.05, 1.0),
                  child: Container(height: 7, color: SR.primary),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text('${admin.decisions}', style: mono(10.5)),
        const SizedBox(width: 10),
        Text(_durationLabel(admin.median), style: mono(10.5)),
      ],
    ),
  );

  Widget _qualityDivider() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(color: context.srColors.divider),
        const SizedBox(height: 6),
        Text(
          'Facility checks use live local facility data and do not depend on the unavailable reporting response.',
          style: sans(11, color: context.srColors.muted),
        ),
      ],
    ),
  );

  Widget _quality(AppState state, List<QualityIssue> issues) {
    final sorted = [...issues]
      ..sort((a, b) {
        final severity = a.severity.index.compareTo(b.severity.index);
        if (severity != 0) return severity;
        return a.facility.name.compareTo(b.facility.name);
      });
    int count(QualitySeverity severity) =>
        issues.where((issue) => issue.severity == severity).length;
    return _section(
      number: '04',
      title: 'Data quality',
      caption: 'Facility checks - live local data',
      tooltip: 'Pins, coordinates, and photos that affect student wayfinding.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _qualityExportButton(
            () => _exportSectionText(
              state,
              baseName: 'smartreserve-data-quality-report',
              label: 'Data quality CSV',
              contents: dataQualityCsv(issues),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _qualityChip('${count(QualitySeverity.blocking)} blocking'),
              _qualityChip('${count(QualitySeverity.warning)} need review'),
              _qualityChip('${count(QualitySeverity.minor)} minor'),
            ],
          ),
          const SizedBox(height: 12),
          if (sorted.isEmpty)
            _empty('Every facility has usable location and catalogue data.')
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 760;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!compact) _qualityTableHeader(),
                    for (final issue in sorted)
                      _qualityRow(issue, compact: compact),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _qualityExportButton(VoidCallback onPressed) {
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    return Align(
      alignment: compact ? Alignment.centerLeft : Alignment.centerRight,
      child: SrButton(
        label: 'Export section CSV',
        icon: const Icon(Icons.download_rounded, size: SR.iconSm),
        dense: true,
        fontSize: 11,
        onPressed: onPressed,
      ),
    );
  }

  Widget _sectionExportButton(VoidCallback onPressed) => Align(
    alignment: Alignment.centerRight,
    child: SrButton(
      label: 'Export section CSV',
      icon: const Icon(Icons.download_rounded, size: SR.iconSm),
      dense: true,
      fontSize: 11,
      onPressed: onPressed,
    ),
  );

  Future<void> _exportSectionText(
    AppState state, {
    required String baseName,
    required String label,
    required String contents,
  }) async {
    final result = await saveTextFile(
      baseName: baseName,
      extension: 'csv',
      contents: contents,
    );
    _toastExportResult(state, result, label);
  }

  Widget _qualityChip(String label) => SrPill(
    label: label,
    background: context.srColors.dividerSoft,
    foreground: context.srColors.ink3,
    fontSize: 10.5,
  );

  Widget _qualityTableHeader() => Container(
    padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: context.srColors.divider)),
    ),
    child: Row(
      children: [
        Expanded(flex: 20, child: Text('Facility', style: keyLabel)),
        const SizedBox(width: 16),
        Expanded(flex: 36, child: Text('Issue', style: keyLabel)),
        const SizedBox(width: 16),
        Expanded(flex: 28, child: Text('Why it matters', style: keyLabel)),
        const SizedBox(width: 16),
        SizedBox(
          width: 150,
          child: Align(
            alignment: Alignment.centerRight,
            child: Text('Action', style: keyLabel),
          ),
        ),
      ],
    ),
  );

  Widget _qualityRow(QualityIssue issue, {required bool compact}) {
    final disabled =
        widget.onResolveQualityIssue == null || !issue.facility.canManage;
    final action = SrButton(
      label: issue.actionLabel,
      dense: true,
      fontSize: 11,
      expand: compact,
      tooltip: disabled ? 'You cannot edit this facility.' : null,
      onPressed: disabled ? null : () => widget.onResolveQualityIssue!(issue),
    );
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 0,
        vertical: compact ? 12 : 11,
      ),
      decoration: BoxDecoration(
        color: compact ? context.srColors.surfaceSubtle : Colors.transparent,
        borderRadius: compact ? BorderRadius.circular(8) : null,
        border: Border(top: BorderSide(color: context.srColors.dividerSoft)),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _qualityFacility(issue),
                const SizedBox(height: 10),
                _qualityLabeledText('Issue', issue.issue),
                const SizedBox(height: 8),
                _qualityLabeledText(
                  'Why it matters',
                  issue.impact,
                  muted: true,
                ),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, child: action),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(flex: 20, child: _qualityFacility(issue)),
                const SizedBox(width: 16),
                Expanded(
                  flex: 36,
                  child: Text(issue.issue, style: sans(11.5, height: 1.45)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 28,
                  child: Text(
                    issue.impact,
                    style: sans(
                      11.3,
                      height: 1.45,
                      color: context.srColors.muted,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 150,
                  child: Align(alignment: Alignment.centerRight, child: action),
                ),
              ],
            ),
    );
  }

  Widget _qualityFacility(QualityIssue issue) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(issue.facility.name, softWrap: true, style: sans(12, w: 600)),
      const SizedBox(height: 5),
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
    ],
  );

  Widget _qualityLabeledText(
    String label,
    String value, {
    bool muted = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: keyLabel),
      const SizedBox(height: 4),
      Text(
        value,
        style: sans(
          11.5,
          height: 1.45,
          color: muted ? context.srColors.muted : null,
        ),
      ),
    ],
  );

  Widget _tableHeader(List<String> labels) => Container(
    padding: const EdgeInsets.symmetric(vertical: 7),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: context.srColors.divider)),
    ),
    child: Row(
      children: [
        for (final label in labels)
          Expanded(child: Text(label, style: keyLabel)),
      ],
    ),
  );

  Widget _dataRow(List<String> values, {required bool compact}) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: context.srColors.dividerSoft)),
    ),
    child: compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(values.first, style: mono(11, w: 500)),
              const SizedBox(height: 4),
              Text(values.skip(1).join(' · '), style: sans(11.2)),
            ],
          )
        : Row(
            children: [
              for (final value in values)
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sans(11.2, color: context.srColors.ink3),
                  ),
                ),
            ],
          ),
  );

  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 18),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: sans(11.5, height: 1.55, color: context.srColors.muted),
    ),
  );

  Future<void> _copyFailureDetails(
    AppState state,
    ReportFailure failure,
  ) async {
    await Clipboard.setData(
      ClipboardData(
        text:
            'SmartReserve report verification failure\n'
            'Scope: ${_scopeLabel(_scope())}\n'
            'Support reference: ${failure.supportReference}\n'
            'Explanation: ${failure.explanation}',
      ),
    );
    state.showToast(const ToastMessage('Report support details copied.'));
  }

  Future<void> _copyReportLink(AppState state) async {
    final link = currentReportLink(
      ReportLinkSelection(
        range: _range,
        category: _selectedCategory,
        facilityId: _drillFacility,
      ),
    );
    await Clipboard.setData(ClipboardData(text: link));
    state.showToast(const ToastMessage('Report link copied.'));
  }

  Future<void> _export(
    AppState state,
    ReportSnapshot? snapshot,
    List<QualityIssue> issues,
    String kind,
  ) async {
    if (snapshot == null) return;
    final stale = state.reportState is ReportStale;
    final failure = state.reportState.failure;
    if (kind == 'csv') {
      final result = await saveTextFile(
        baseName: 'smartreserve-full-report',
        extension: 'csv',
        contents: fullReportCsv(
          snapshot: snapshot,
          issues: issues,
          exportedBy: state.currentAdmin.name,
          canViewPerAdmin: state.isInternalAdmin,
          canViewRevenue: state.isExternalAdmin,
          stale: stale,
          staleReason: failure?.explanation,
        ),
      );
      _toastExportResult(state, result, 'CSV');
      return;
    }
    final bytes = await buildReportPdf(
      snapshot: snapshot,
      issues: issues,
      exportedBy: state.currentAdmin.name,
      canViewPerAdmin: state.isInternalAdmin,
      canViewRevenue: state.isExternalAdmin,
      stale: stale,
      staleReason: failure?.explanation,
    );
    final result = await saveBinaryFile(
      baseName: 'smartreserve-full-report',
      extension: 'pdf',
      bytes: bytes,
    );
    _toastExportResult(state, result, 'PDF');
  }

  void _toastExportResult(
    AppState state,
    FileExportResult result,
    String label,
  ) {
    if (!mounted) return;
    state.showToast(
      result.ok
          ? ToastMessage(
              '$label report saved${result.path == null ? '.' : ' to ${result.path}.'}',
              tone: AdvisoryTone.info,
              action: result.revealSupported
                  ? ToastAction(
                      label: 'Open',
                      onPressed: () => revealInFileExplorer(result.path!),
                    )
                  : null,
            )
          : ToastMessage(
              "$label report couldn't be saved. Check the destination and try again.",
              tone: AdvisoryTone.block,
            ),
    );
  }

  List<String> _liveCategories(AppState state) =>
      state.facilities.map((facility) => facility.category).toSet().toList()
        ..sort();

  String _scopeLabel(ReportScope scope) =>
      '${formatDay(campusWallTime(scope.from))} - ${formatDay(campusWallTime(scope.to))}; '
      '${scope.category ?? 'All categories'}; Asia/Manila';

  String _reportTimestamp(DateTime value) {
    final local = campusWallTime(value);
    return '${formatCampusDate(local)} ${_clock(local)}';
  }

  String _monthLabel(DateTime value) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final local = campusWallTime(value);
    return '${months[local.month - 1]} ${local.year}';
  }

  String _relativeFreshness(DateTime generatedAt) {
    final delta = DateTime.now().difference(generatedAt);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) return '${delta.inHours} h ago';
    return _reportTimestamp(generatedAt);
  }

  String _clock(DateTime value) =>
      formatClock12(value.hour + value.minute / 60);

  String _durationLabel(double value) => value < 24
      ? '${value.round()} h'
      : '${(value / 24).toStringAsFixed(1)} d';

  String _weekday(int day) => const [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ][day - 1];
}

class _DemandSelection {
  const _DemandSelection(this.day, this.hour);

  final int day;
  final int hour;

  bool matches(ReportBookedOccurrence occurrence) {
    final start = campusWallTime(occurrence.startsAt);
    final end = campusWallTime(occurrence.endsAt);
    final cursor = DateTime(start.year, start.month, start.day, hour);
    final blockEnd = cursor.add(const Duration(hours: 2));
    return start.weekday == day &&
        start.isBefore(blockEnd) &&
        end.isAfter(cursor);
  }

  @override
  bool operator ==(Object other) =>
      other is _DemandSelection && other.day == day && other.hour == hour;

  @override
  int get hashCode => Object.hash(day, hour);
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
    return Semantics(
      button: true,
      selected: selected,
      label:
          '${row.facilityName}, ${formatUtilisationPercent(row.fraction)} utilised',
      child: FocusableActionDetector(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap();
              return null;
            },
          ),
        },
        child: Hoverable(
          builder: (context, hovered) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: AnimatedContainer(
              duration: SR.stateChange,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: hovered
                    ? context.srColors.surfaceSubtle
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                border: selected
                    ? Border.all(color: context.srColors.primaryLine)
                    : Border.all(color: Colors.transparent),
              ),
              child: compact ? _compact(context) : _wide(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _compact(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text(row.facilityName, style: sans(12.5, w: 600))),
          Text(formatUtilisationPercent(row.fraction), style: mono(12, w: 600)),
        ],
      ),
      const SizedBox(height: 4),
      Text(row.building, style: sans(10.5, color: context.srColors.muted)),
      const SizedBox(height: 8),
      _bar(context),
      const SizedBox(height: 5),
      Text(
        '${row.bookedHours.toStringAsFixed(2)} / ${row.availableHours.toStringAsFixed(2)} h',
        style: mono(10, color: context.srColors.muted),
      ),
    ],
  );

  Widget _wide(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 220,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              row.facilityName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sans(12, w: 600),
            ),
            Text(
              row.building,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sans(10.5, color: context.srColors.muted),
            ),
          ],
        ),
      ),
      const SizedBox(width: 12),
      Expanded(child: _bar(context)),
      const SizedBox(width: 12),
      SizedBox(
        width: 62,
        child: Text(
          formatUtilisationPercent(row.fraction),
          textAlign: TextAlign.right,
          style: mono(12, w: 600),
        ),
      ),
      const SizedBox(width: 12),
      SizedBox(
        width: 124,
        child: Text(
          '${row.bookedHours.toStringAsFixed(2)} / ${row.availableHours.toStringAsFixed(2)} h',
          textAlign: TextAlign.right,
          style: mono(10.5, color: context.srColors.muted),
        ),
      ),
    ],
  );

  Widget _bar(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: Stack(
      children: [
        Container(height: 9, color: context.srColors.divider),
        AnimatedFractionallySizedBox(
          duration: SR.entrance,
          curve: SR.easing,
          widthFactor: row.fraction.clamp(0.0, 1.0),
          child: Container(
            height: 9,
            color: row.fraction < .25
                ? SR.orange
                : row.fraction < .6
                ? SR.primaryBright
                : SR.primary,
          ),
        ),
      ],
    ),
  );
}

class _HeatCell extends StatelessWidget {
  const _HeatCell({
    required this.count,
    required this.peak,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  final int count;
  final int peak;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final intensity = peak == 0 ? 0.0 : count / peak;
    final color = count == 0
        ? context.srColors.divider
        : Color.lerp(context.srColors.primaryTint, SR.primary, intensity);
    return Semantics(
      button: true,
      label: label,
      selected: selected,
      child: Tooltip(
        message: label,
        child: FocusableActionDetector(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                onTap();
                return null;
              },
            ),
          },
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 40,
              height: 30,
              margin: const EdgeInsets.only(right: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(5),
                border: selected
                    ? Border.all(color: SR.primaryHover, width: 2)
                    : null,
              ),
              child: Text(
                count == 0 ? '' : '$count',
                style: mono(
                  9.5,
                  w: 600,
                  color: intensity > .55
                      ? context.srColors.surface
                      : SR.primaryHover,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
