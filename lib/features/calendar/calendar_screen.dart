import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../app/app_view.dart';
import '../../model/calendar_event.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';

import '../../theme/sr_theme.dart';

const _minimumStartHour = 7;
const _minimumEndHour = 20;
const _hourHeight = 48.0;

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const _CalendarFrame(surface: _CalendarSurface.admin);
}

class PublicCalendarScreen extends StatefulWidget {
  const PublicCalendarScreen({super.key});

  @override
  State<PublicCalendarScreen> createState() => _PublicCalendarScreenState();
}

class _PublicCalendarScreenState extends State<PublicCalendarScreen> {
  bool _requestedInitialLoad = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requestedInitialLoad) return;
    _requestedInitialLoad = true;
    final state = AppScope.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(state.ensureUserCalendarLoaded());
    });
  }

  @override
  Widget build(BuildContext context) =>
      const _CalendarFrame(surface: _CalendarSurface.public);
}

enum _CalendarSurface { admin, public }

class _CalendarFrame extends StatefulWidget {
  const _CalendarFrame({this.surface = _CalendarSurface.admin});

  final _CalendarSurface surface;

  @override
  State<_CalendarFrame> createState() => _CalendarFrameState();
}

class _CalendarFrameState extends State<_CalendarFrame> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final data = _CalendarData.fromState(state, widget.surface);
    final compact = MediaQuery.sizeOf(context).width < SR.tabletMin;
    final selected = data.selectedEvent;
    final calendar = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(data: data, search: _search, compact: compact),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 14 : 20,
              14,
              compact ? 14 : 20,
              24,
            ),
            child: _CalendarBody(
              data: data,
              compact: compact,
              onClearFilters: () {
                _search.clear();
                data.resetFilters();
              },
            ),
          ),
        ),
      ],
    );

    if (compact) {
      return Stack(
        children: [
          calendar,
          if (selected != null)
            Positioned.fill(
              child: _MobileDetails(
                event: selected,
                onClose: () => data.onSelectEvent?.call(null),
                onOpenRequest: selected.canOpenRequest
                    ? () => state.openRequestFromCalendar(selected)
                    : null,
              ),
            ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: calendar),
        if (selected != null)
          SizedBox(
            width: 330,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.srColors.surface,
                border: Border(
                  left: BorderSide(color: context.srColors.border),
                ),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
                child: _EventDetails(
                  event: selected,
                  onClose: () => data.onSelectEvent?.call(null),
                  onOpenRequest: selected.canOpenRequest
                      ? () => state.openRequestFromCalendar(selected)
                      : null,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CalendarData {
  const _CalendarData({
    required this.surface,
    required this.anchor,
    required this.today,
    required this.viewMode,
    required this.facilityFilter,
    required this.facilities,
    required this.displayFacilities,
    required this.allEvents,
    required this.visibleEvents,
    required this.loading,
    required this.error,
    required this.query,
    required this.usesDefaultStatusFilters,
    required this.onViewMode,
    required this.onFacilityFilter,
    required this.onNavigate,
    required this.onToday,
    required this.onSelectDate,
    required this.onSelectEvent,
    required this.onRefresh,
    required this.resetFilters,
    this.selectedEvent,
  });

  factory _CalendarData.fromState(AppState state, _CalendarSurface surface) {
    if (surface == _CalendarSurface.public) {
      return _CalendarData(
        surface: surface,
        anchor: state.userCalendarAnchor,
        today: state.calendarToday,
        viewMode: state.userCalendarViewMode,
        facilityFilter: state.userCalendarFacilityFilter,
        facilities: state.userCalendarFacilities,
        displayFacilities: [
          for (final facility in state.publicCalendarFacilities) facility.name,
        ]..sort(),
        allEvents: state.userCalendarEvents,
        visibleEvents: state.visibleUserCalendarEvents,
        loading: state.userCalendarLoading,
        error: state.userCalendarError,
        query: '',
        usesDefaultStatusFilters: true,
        onViewMode: state.setUserCalendarViewMode,
        onFacilityFilter: state.setUserCalendarFacilityFilter,
        onNavigate: state.navigateUserCalendar,
        onToday: state.goToUserCalendarToday,
        onSelectDate: state.selectUserCalendarDate,
        onSelectEvent: null,
        onRefresh: state.refreshUserCalendar,
        resetFilters: () =>
            state.setUserCalendarFacilityFilter('All facilities'),
      );
    }
    return _CalendarData(
      surface: surface,
      anchor: state.calendarAnchor,
      today: state.calendarToday,
      viewMode: state.calendarViewMode,
      facilityFilter: state.calendarFacilityFilter,
      facilities: state.calendarFacilities,
      displayFacilities: state.scheduleFacilities,
      allEvents: state.calendarEvents,
      visibleEvents: state.visibleCalendarEvents,
      loading: state.reservationsLoading,
      error: state.reservationsError,
      query: state.calendarQuery,
      usesDefaultStatusFilters: setEquals(
        state.calendarStates,
        CalendarEventState.defaultVisible,
      ),
      selectedEvent: state.selectedCalendarEvent,
      onViewMode: state.setCalendarViewMode,
      onFacilityFilter: state.setCalendarFacilityFilter,
      onNavigate: state.navigateCalendar,
      onToday: state.goToCalendarToday,
      onSelectDate: state.selectCalendarDate,
      onSelectEvent: state.selectCalendarEvent,
      onRefresh: state.refreshReservations,
      resetFilters: state.resetCalendarFilters,
    );
  }

  final _CalendarSurface surface;
  final DateTime anchor;
  final DateTime today;
  final CalendarViewMode viewMode;
  final String facilityFilter;
  final List<String> facilities;
  final List<String> displayFacilities;
  final List<CalendarEvent> allEvents;
  final List<CalendarEvent> visibleEvents;
  final bool loading;
  final String? error;
  final String query;
  final bool usesDefaultStatusFilters;
  final CalendarEvent? selectedEvent;
  final ValueChanged<CalendarViewMode> onViewMode;
  final ValueChanged<String> onFacilityFilter;
  final ValueChanged<int> onNavigate;
  final VoidCallback onToday;
  final void Function(DateTime date, {CalendarViewMode? mode}) onSelectDate;
  final ValueChanged<String?>? onSelectEvent;
  final Future<void> Function() onRefresh;
  final VoidCallback resetFilters;

  bool get isPublic => surface == _CalendarSurface.public;
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.data,
    required this.search,
    required this.compact,
  });

  final _CalendarData data;
  final TextEditingController search;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.fromLTRB(compact ? 14 : 20, 10, compact ? 14 : 20, 10),
    decoration: BoxDecoration(
      color: context.srColors.surface,
      border: Border(bottom: BorderSide(color: context.srColors.border)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compact)
          _compactNavigation(context)
        else
          _expandedNavigation(context),
        SizedBox(height: compact ? 8 : 9),
        if (compact)
          Row(
            key: const Key('compact-calendar-search-row'),
            children: [
              Expanded(
                child: SizedBox(
                  key: const Key('compact-calendar-search'),
                  height: 44,
                  child: data.isPublic
                      ? FilterSelect(
                          value: data.facilityFilter,
                          items: data.facilities,
                          semanticLabel: 'Filter reserved dates by facility',
                          onChanged: data.onFacilityFilter,
                        )
                      : FilterSearch(
                          controller: search,
                          placeholder: 'Search reservations',
                          width: double.infinity,
                          onChanged: AppScope.of(context).setCalendarQuery,
                        ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                key: const Key('compact-calendar-filters'),
                height: 44,
                child: data.isPublic
                    ? SrIconButton(
                        icon: Icons.refresh_rounded,
                        fontSize: 14,
                        tooltip: 'Refresh reserved dates',
                        onPressed: () => unawaited(data.onRefresh()),
                      )
                    : CompactFilterButton(
                        activeCount:
                            (data.facilityFilter == 'All facilities' ? 0 : 1) +
                            (AppScope.of(context).calendarStates.length ==
                                    CalendarEventState.defaultVisible.length
                                ? 0
                                : 1),
                        onPressed: () => _openFilters(context),
                      ),
              ),
            ],
          )
        else ...[
          FilterBar(
            count: '${data.visibleEvents.length} shown',
            children: [
              SizedBox(
                width: 240,
                child: FilterSelect(
                  value: data.facilityFilter,
                  items: data.facilities,
                  semanticLabel: data.isPublic
                      ? 'Filter reserved dates by facility'
                      : 'Filter calendar by facility',
                  onChanged: data.onFacilityFilter,
                ),
              ),
              if (!data.isPublic)
                FilterSearch(
                  controller: search,
                  placeholder: 'Search reservations',
                  width: 260,
                  onChanged: AppScope.of(context).setCalendarQuery,
                )
              else
                SrIconButton(
                  icon: Icons.refresh_rounded,
                  fontSize: 14,
                  tooltip: 'Refresh reserved dates',
                  onPressed: () => unawaited(data.onRefresh()),
                ),
            ],
          ),
          if (data.isPublic)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Only facility, date, and time are shown. Requester identity and purpose stay private.',
                style: sans(11.5, height: 1.45, color: context.srColors.ink4),
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final status in CalendarEventState.values)
                  FilterPill(
                    label: status.label,
                    selected: AppScope.of(
                      context,
                    ).calendarStates.contains(status),
                    onTap: () =>
                        AppScope.of(context).toggleCalendarState(status),
                  ),
              ],
            ),
        ],
      ],
    ),
  );

  Widget _expandedNavigation(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      _modeSegment(context, expand: false),
      SrIconButton(
        icon: Icons.chevron_left_rounded,
        fontSize: 14,
        tooltip: 'Previous ${data.viewMode.label.toLowerCase()}',
        onPressed: () => data.onNavigate(-1),
      ),
      SrButton(
        label: _rangeLabel(data),
        dense: true,
        kind: SrButtonKind.ghost,
        onPressed: data.onToday,
        tooltip: 'Go to today',
      ),
      SrIconButton(
        icon: Icons.chevron_right_rounded,
        fontSize: 14,
        tooltip: 'Next ${data.viewMode.label.toLowerCase()}',
        onPressed: () => data.onNavigate(1),
      ),
    ],
  );

  Widget _compactNavigation(BuildContext context) => SizedBox(
    key: const Key('compact-calendar-navigation'),
    height: 44,
    child: Row(
      children: [
        Expanded(child: _modeSegment(context, expand: true, compact: true)),
        const SizedBox(width: 3),
        _CompactCalendarNavButton(
          key: const Key('compact-calendar-previous'),
          icon: Icons.chevron_left_rounded,
          tooltip: 'Previous ${data.viewMode.label.toLowerCase()}',
          onPressed: () => data.onNavigate(-1),
          width: 32,
        ),
        const SizedBox(width: 3),
        SizedBox(
          key: const Key('compact-calendar-range'),
          width: MediaQuery.sizeOf(context).width < 360 ? 56 : 64,
          child: Tooltip(
            message: 'Go to today',
            child: Semantics(
              button: true,
              label: 'Go to today',
              child: GestureDetector(
                onTap: data.onToday,
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _compactRangeLabel(data),
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: sans(11.5, w: 500, color: context.srColors.ink2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 3),
        _CompactCalendarNavButton(
          key: const Key('compact-calendar-next'),
          icon: Icons.chevron_right_rounded,
          tooltip: 'Next ${data.viewMode.label.toLowerCase()}',
          onPressed: () => data.onNavigate(1),
          width: 32,
        ),
      ],
    ),
  );

  Widget _modeSegment(
    BuildContext context, {
    required bool expand,
    bool compact = false,
  }) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: context.srColors.dividerSoft,
      borderRadius: BorderRadius.circular(9),
    ),
    child: Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        for (final mode in CalendarViewMode.values)
          expand
              ? Expanded(
                  child: _ModeTab(
                    key: ValueKey('calendar-mode-${mode.name}'),
                    label: mode.label,
                    selected: data.viewMode == mode,
                    onTap: () => data.onViewMode(mode),
                    compact: compact,
                  ),
                )
              : _ModeTab(
                  key: ValueKey('calendar-mode-${mode.name}'),
                  label: mode.label,
                  selected: data.viewMode == mode,
                  onTap: () => data.onViewMode(mode),
                ),
      ],
    ),
  );

  Future<void> _openFilters(BuildContext context) => showSrFilterSheet(
    context,
    title: 'Filter calendar',
    child: StatefulBuilder(
      builder: (context, sheetSetState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SrLabel('Facility'),
          FilterSelect(
            value: data.facilityFilter,
            items: data.facilities,
            semanticLabel: 'Filter calendar by facility',
            onChanged: (value) {
              data.onFacilityFilter(value);
              sheetSetState(() {});
            },
          ),
          const SizedBox(height: 16),
          const SrLabel('Reservation status'),
          for (final status in CalendarEventState.values)
            CheckboxListTile(
              value: AppScope.of(context).calendarStates.contains(status),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(status.label, style: sans(12.5)),
              onChanged: (_) {
                AppScope.of(context).toggleCalendarState(status);
                sheetSetState(() {});
              },
            ),
          const SizedBox(height: 10),
          SrButton(
            label: 'Show reservations',
            kind: SrButtonKind.primary,
            expand: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    ),
  );

  String _rangeLabel(_CalendarData data) => switch (data.viewMode) {
    CalendarViewMode.month =>
      '${monthNames[data.anchor.month - 1]} ${data.anchor.year}',
    CalendarViewMode.week =>
      '${formatCampusDate(_weekStart(data.anchor))} – ${formatCampusDate(_weekStart(data.anchor).add(const Duration(days: 6)))}',
    CalendarViewMode.day => formatCampusDate(data.anchor),
  };

  String _compactRangeLabel(_CalendarData data) => switch (data.viewMode) {
    CalendarViewMode.month =>
      '${monthNames[data.anchor.month - 1]} ${data.anchor.year}',
    CalendarViewMode.week =>
      '${_weekStart(data.anchor).day}–${_weekStart(data.anchor).add(const Duration(days: 6)).day} ${monthNames[_weekStart(data.anchor).add(const Duration(days: 6)).month - 1]}',
    CalendarViewMode.day => formatCampusDate(data.anchor),
  };
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: SR.stateChange,
        alignment: Alignment.center,
        constraints: BoxConstraints(
          minHeight: compact
              ? 38
              : (SR.isCompact(MediaQuery.sizeOf(context).width) ? 44 : 0),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 2 : 10,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: selected ? context.srColors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          boxShadow: selected ? SR.cardShadow : null,
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: sans(
            compact ? 10.5 : 11.5,
            w: 500,
            color: selected ? context.srColors.ink : context.srColors.ink4,
          ),
        ),
      ),
    ),
  );
}

class _CompactCalendarNavButton extends StatelessWidget {
  const _CompactCalendarNavButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.width = 36,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double width;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: width,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.srColors.surface,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: context.srColors.border),
          ),
          child: Icon(icon, size: 17, color: context.srColors.ink2),
        ),
      ),
    ),
  );
}

class _CalendarBody extends StatelessWidget {
  const _CalendarBody({
    required this.data,
    required this.compact,
    required this.onClearFilters,
  });
  final _CalendarData data;
  final bool compact;
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context) {
    if (data.loading && data.allEvents.isEmpty) {
      return SingleChildScrollView(
        child: _CalendarStatusCard(
          icon: Icons.hourglass_top_rounded,
          title: data.isPublic
              ? 'Loading reserved dates'
              : 'Loading reservations',
          body: data.isPublic
              ? 'Checking the latest facility schedule.'
              : 'Checking the latest reservation activity.',
        ),
      );
    }
    if (data.error != null && data.allEvents.isEmpty) {
      return SingleChildScrollView(
        child: _CalendarStatusCard(
          icon: Icons.wifi_off_rounded,
          title: data.isPublic
              ? 'Reserved dates could not load'
              : 'Reservations could not load',
          body: data.error!,
          action: SrButton(
            label: 'Retry',
            kind: SrButtonKind.primary,
            onPressed: () => unawaited(data.onRefresh()),
          ),
        ),
      );
    }

    final emptyState = _calendarEmptyState(data);
    final calendar = switch (data.viewMode) {
      CalendarViewMode.month => _MonthView(data: data, compact: compact),
      CalendarViewMode.week when compact => _CompactAgenda(data: data),
      CalendarViewMode.day when compact => _CompactAgenda(data: data),
      CalendarViewMode.week => _WeekView(data: data),
      CalendarViewMode.day => _DayView(data: data),
    };

    if (emptyState == null) return calendar;
    final card = _CalendarEmptyStateCard(
      data: data,
      emptyState: emptyState,
      compact: !compact && emptyState == _CalendarEmptyState.emptyRange,
      onClearFilters: onClearFilters,
    );
    if (compact || emptyState != _CalendarEmptyState.emptyRange) {
      return SingleChildScrollView(child: card);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        card,
        const SizedBox(height: 12),
        Expanded(child: calendar),
      ],
    );
  }
}

enum _CalendarEmptyState { noData, noMatches, emptyRange }

class _CalendarStatusCard extends StatelessWidget {
  const _CalendarStatusCard({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
    decoration: BoxDecoration(
      color: context.srColors.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.srColors.border),
    ),
    child: Column(
      children: [
        Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.srColors.primaryTint,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: context.srColors.primaryLine),
          ),
          child: Icon(icon, size: 22, color: SR.primaryHover),
        ),
        const SizedBox(height: 16),
        Text(title, textAlign: TextAlign.center, style: sans(14.5, w: 600)),
        const SizedBox(height: 5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Text(
            body,
            textAlign: TextAlign.center,
            style: sans(12, height: 1.55, color: context.srColors.ink4),
          ),
        ),
        if (action != null) ...[const SizedBox(height: 18), action!],
      ],
    ),
  );
}

_CalendarEmptyState? _calendarEmptyState(_CalendarData data) {
  if (data.loading || data.error != null) return null;
  final allEvents = data.allEvents;
  if (allEvents.isEmpty) return _CalendarEmptyState.noData;

  final visibleEvents = data.visibleEvents;
  if (visibleEvents.any((event) => _eventIsInActiveRange(data, event))) {
    return null;
  }

  final hasActiveFilters =
      data.facilityFilter != 'All facilities' ||
      data.query.trim().isNotEmpty ||
      !data.usesDefaultStatusFilters;
  final rangeHasUnfilteredEvents = allEvents.any(
    (event) => _eventIsInActiveRange(data, event),
  );
  if (hasActiveFilters && (visibleEvents.isEmpty || rangeHasUnfilteredEvents)) {
    return _CalendarEmptyState.noMatches;
  }
  return _CalendarEmptyState.emptyRange;
}

bool _eventIsInActiveRange(_CalendarData data, CalendarEvent event) {
  final anchor = data.anchor;
  final (start, end) = switch (data.viewMode) {
    CalendarViewMode.month => (
      DateTime(anchor.year, anchor.month),
      DateTime(anchor.year, anchor.month + 1),
    ),
    CalendarViewMode.week => (
      _weekStart(anchor),
      _weekStart(anchor).add(const Duration(days: 7)),
    ),
    CalendarViewMode.day => (
      DateTime(anchor.year, anchor.month, anchor.day),
      DateTime(anchor.year, anchor.month, anchor.day + 1),
    ),
  };
  return event.startsAt.isBefore(end) && event.endsAt.isAfter(start);
}

bool _activeRangeContainsToday(_CalendarData data) {
  final today = data.today;
  final anchor = data.anchor;
  return switch (data.viewMode) {
    CalendarViewMode.month =>
      anchor.year == today.year && anchor.month == today.month,
    CalendarViewMode.week =>
      !_weekStart(today).isBefore(_weekStart(anchor)) &&
          _weekStart(
            today,
          ).isBefore(_weekStart(anchor).add(const Duration(days: 7))),
    CalendarViewMode.day =>
      anchor.year == today.year &&
          anchor.month == today.month &&
          anchor.day == today.day,
  };
}

class _CalendarEmptyStateCard extends StatelessWidget {
  const _CalendarEmptyStateCard({
    required this.data,
    required this.emptyState,
    required this.compact,
    required this.onClearFilters,
  });

  final _CalendarData data;
  final _CalendarEmptyState emptyState;
  final bool compact;
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context) {
    final title = switch (emptyState) {
      _CalendarEmptyState.noData =>
        data.isPublic ? 'No reserved slots yet' : 'No reservations yet',
      _CalendarEmptyState.noMatches =>
        data.isPublic
            ? 'No reserved slots match this facility'
            : 'No reservations match your filters',
      _CalendarEmptyState.emptyRange =>
        data.isPublic
            ? 'No reserved slots this ${data.viewMode.label.toLowerCase()}'
            : 'No reservations this ${data.viewMode.label.toLowerCase()}',
    };
    final body = switch (emptyState) {
      _CalendarEmptyState.noData when data.isPublic =>
        'Reserved public-facility slots will appear here once they are confirmed or held.',
      _CalendarEmptyState.noData =>
        'Reservation occurrences will appear here after requests are submitted.',
      _CalendarEmptyState.noMatches when data.isPublic =>
        'Choose all facilities or another facility to see more reserved times.',
      _CalendarEmptyState.noMatches =>
        'Clear the search, facility, or status filters to see more reservations.',
      _CalendarEmptyState.emptyRange =>
        'This ${data.viewMode.label.toLowerCase()} is open. Use the calendar navigation to check another date range.',
    };
    final action = switch (emptyState) {
      _CalendarEmptyState.noData when data.isPublic => SrButton(
        label: 'Refresh',
        kind: SrButtonKind.primary,
        onPressed: () => unawaited(data.onRefresh()),
      ),
      _CalendarEmptyState.noData => SrButton(
        label: 'View reservation requests',
        kind: SrButtonKind.primary,
        onPressed: () => AppScope.of(context).goTo(AppView.reservations),
      ),
      _CalendarEmptyState.noMatches => SrButton(
        key: const Key('calendar-clear-filters'),
        label: 'Clear filters',
        onPressed: onClearFilters,
      ),
      _CalendarEmptyState.emptyRange when !_activeRangeContainsToday(data) =>
        SrButton(
          key: const Key('calendar-go-to-today'),
          label: 'Go to today',
          onPressed: data.onToday,
        ),
      _ => null,
    };

    return Semantics(
      container: true,
      child: Container(
        key: Key('calendar-empty-${emptyState.name}'),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 18 : 24,
          vertical: compact ? 16 : 40,
        ),
        decoration: BoxDecoration(
          color: context.srColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.srColors.border),
        ),
        child: compact
            ? Row(
                children: [
                  _CalendarEmptyIcon(compact: true),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _CalendarEmptyCopy(title: title, body: body),
                  ),
                  if (action != null) ...[const SizedBox(width: 14), action],
                ],
              )
            : Column(
                children: [
                  const _CalendarEmptyIcon(),
                  const SizedBox(height: 16),
                  _CalendarEmptyCopy(title: title, body: body, centered: true),
                  if (action != null) ...[const SizedBox(height: 18), action],
                ],
              ),
      ),
    );
  }
}

class _CalendarEmptyIcon extends StatelessWidget {
  const _CalendarEmptyIcon({this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    width: compact ? 40 : 48,
    height: compact ? 40 : 48,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: context.srColors.primaryTint,
      borderRadius: BorderRadius.circular(compact ? 11 : 14),
      border: Border.all(color: context.srColors.primaryLine),
    ),
    child: Icon(
      Icons.calendar_month_outlined,
      size: compact ? 19 : 22,
      color: SR.primaryHover,
    ),
  );
}

class _CalendarEmptyCopy extends StatelessWidget {
  const _CalendarEmptyCopy({
    required this.title,
    required this.body,
    this.centered = false,
  });
  final String title;
  final String body;
  final bool centered;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: Text(
          title,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: sans(14.5, w: 600),
        ),
      ),
      const SizedBox(height: 5),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: Text(
          body,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: sans(12, height: 1.55, color: context.srColors.ink4),
        ),
      ),
    ],
  );
}

class _CompactAgenda extends StatelessWidget {
  const _CompactAgenda({required this.data});

  final _CalendarData data;

  @override
  Widget build(BuildContext context) {
    final events = [
      for (final event in data.visibleEvents)
        if (_eventIsInActiveRange(data, event)) event,
    ]..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    if (events.isEmpty) return const SizedBox.shrink();

    DateTime? previousDay;
    return ListView.builder(
      key: const Key('compact-calendar-agenda'),
      itemCount: events.length,
      itemBuilder: (context, index) {
        final event = events[index];
        final day = DateTime(
          event.startsAt.year,
          event.startsAt.month,
          event.startsAt.day,
        );
        final showDay = previousDay != day;
        previousDay = day;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showDay)
              Padding(
                padding: EdgeInsets.only(top: index == 0 ? 0 : 12, bottom: 7),
                child: Text(
                  formatCampusDate(day),
                  style: sans(12.5, w: 600, color: context.srColors.ink2),
                ),
              ),
            Semantics(
              button: data.onSelectEvent != null,
              label: '${event.facility}, ${event.timeLabel}',
              child: InkWell(
                borderRadius: BorderRadius.circular(11),
                onTap: data.onSelectEvent == null
                    ? null
                    : () => data.onSelectEvent!(event.id),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: context.srColors.surface,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: event.state.border),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 70,
                        child: Text(
                          event.timeLabel,
                          style: mono(
                            10.5,
                            w: 500,
                            color: context.srColors.ink3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              event.facility,
                              style: sans(12.5, w: 600, height: 1.35),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              event.effectiveSummaryLabel,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: sans(
                                11,
                                height: 1.45,
                                color: context.srColors.ink4,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _StatusBadge(event: event),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MonthView extends StatelessWidget {
  const _MonthView({required this.data, this.compact = false});
  final _CalendarData data;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(data.anchor.year, data.anchor.month);
    final start = first.subtract(Duration(days: first.weekday - 1));
    final events = data.visibleEvents;
    return SrScrollView(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 760.0;
          final narrow = !compact && availableWidth < 760;
          final grid = SizedBox(
            width: narrow ? 760 : availableWidth,
            child: _grid(
              context,
              start,
              events,
              compact ? 62 : (narrow ? 104 : 118),
            ),
          );
          return narrow
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: grid,
                )
              : grid;
        },
      ),
    );
  }

  Widget _grid(
    BuildContext context,
    DateTime start,
    List<CalendarEvent> events,
    double height,
  ) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: context.srColors.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.srColors.border),
    ),
    child: Column(
      children: [
        Row(
          children: [
            for (final day in weekdayNames)
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: context.srColors.hairline),
                    ),
                  ),
                  child: Text(day.toUpperCase(), style: keyLabel),
                ),
              ),
          ],
        ),
        for (var week = 0; week < 6; week++)
          SizedBox(
            height: height,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < 7; index++)
                  Expanded(
                    child: _MonthCell(
                      day: start.add(Duration(days: week * 7 + index)),
                      currentMonth: data.anchor.month,
                      events: [
                        for (final event in events)
                          if (event.overlapsDay(
                            start.add(Duration(days: week * 7 + index)),
                          ))
                            event,
                      ],
                      onSelectDay: () => data.onSelectDate(
                        start.add(Duration(days: week * 7 + index)),
                        mode: CalendarViewMode.day,
                      ),
                      onSelectEvent: data.onSelectEvent == null
                          ? null
                          : (event) => data.onSelectEvent!(event.id),
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _MonthCell extends StatelessWidget {
  const _MonthCell({
    required this.day,
    required this.currentMonth,
    required this.events,
    required this.onSelectDay,
    required this.onSelectEvent,
  });
  final DateTime day;
  final int currentMonth;
  final List<CalendarEvent> events;
  final VoidCallback onSelectDay;
  final ValueChanged<CalendarEvent>? onSelectEvent;

  @override
  Widget build(BuildContext context) {
    final outside = day.month != currentMonth;
    final shown = events.take(2).toList();
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: context.srColors.divider),
          bottom: BorderSide(color: context.srColors.divider),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: onSelectDay,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: 23,
                height: 23,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _isToday(day) ? SR.primary : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${day.day}',
                  style: mono(
                    10,
                    w: 500,
                    color: _isToday(day)
                        ? context.srColors.surface
                        : (outside
                              ? context.srColors.mutedLight
                              : context.srColors.ink3),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          for (final event in shown) ...[
            _EventChip(
              event: event,
              compact: true,
              onTap: onSelectEvent == null ? null : () => onSelectEvent!(event),
            ),
            const SizedBox(height: 3),
          ],
          if (events.length > shown.length)
            GestureDetector(
              onTap: onSelectDay,
              child: Padding(
                padding: const EdgeInsets.only(left: 3, top: 1),
                child: Text(
                  '+${events.length - shown.length} more',
                  style: sans(9.5, w: 500, color: SR.primary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WeekView extends StatelessWidget {
  const _WeekView({required this.data});
  final _CalendarData data;

  @override
  Widget build(BuildContext context) {
    final start = _weekStart(data.anchor);
    final days = [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
    final events = data.visibleEvents;
    final range = _hourRange(
      events.where(
        (event) =>
            event.startsAt.isBefore(start.add(const Duration(days: 7))) &&
            event.endsAt.isAfter(start),
      ),
    );
    final height = (range.$2 - range.$1) * _hourHeight;
    return SrScrollView(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final content = _weekGrid(context, days, events, range, height);
          return constraints.maxWidth < 820
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: 900, child: content),
                )
              : content;
        },
      ),
    );
  }

  Widget _weekGrid(
    BuildContext context,
    List<DateTime> days,
    List<CalendarEvent> events,
    (double, double) range,
    double height,
  ) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: context.srColors.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.srColors.border),
    ),
    child: Column(
      children: [
        Row(
          children: [
            const SizedBox(width: 52),
            for (final day in days)
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: context.srColors.divider),
                      bottom: BorderSide(color: context.srColors.hairline),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        weekdayNames[day.weekday - 1],
                        style: sans(11, w: 600),
                      ),
                      Text(
                        '${day.day} ${monthNames[day.month - 1]}',
                        style: mono(9.5, color: context.srColors.muted),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TimeLabels(range: range),
              for (final day in days)
                Expanded(
                  child: _TimedDayColumn(
                    day: day,
                    events: events,
                    range: range,
                    onSelect: data.onSelectEvent == null
                        ? null
                        : (event) => data.onSelectEvent!(event.id),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _DayView extends StatelessWidget {
  const _DayView({required this.data});
  final _CalendarData data;

  @override
  Widget build(BuildContext context) {
    final day = DateTime(data.anchor.year, data.anchor.month, data.anchor.day);
    final events = [
      for (final event in data.visibleEvents)
        if (event.overlapsDay(day)) event,
    ];
    final facilities = data.facilityFilter == 'All facilities'
        ? data.displayFacilities
        : [data.facilityFilter];
    final range = _hourRange(events);
    return SrScrollView(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final grid = _dayGrid(context, day, facilities, events, range);
          return constraints.maxWidth < 760
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: 760, child: grid),
                )
              : grid;
        },
      ),
    );
  }

  Widget _dayGrid(
    BuildContext context,
    DateTime day,
    List<String> facilities,
    List<CalendarEvent> events,
    (double, double) range,
  ) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: context.srColors.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.srColors.border),
    ),
    child: Column(
      children: [
        Container(
          height: 36,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: context.srColors.hairline),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 190,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Text('FACILITY', style: keyLabel),
                ),
              ),
              Expanded(child: _HorizontalTimeLabels(range: range)),
            ],
          ),
        ),
        if (facilities.isEmpty)
          _EmptyCalendar(message: 'No facilities match this filter.')
        else
          for (final facility in facilities)
            _FacilityRow(
              facility: facility,
              day: day,
              events: [
                for (final event in events)
                  if (event.facility == facility) event,
              ],
              range: range,
              onSelect: data.onSelectEvent == null
                  ? null
                  : (event) => data.onSelectEvent!(event.id),
            ),
      ],
    ),
  );
}

class _TimedDayColumn extends StatelessWidget {
  const _TimedDayColumn({
    required this.day,
    required this.events,
    required this.range,
    required this.onSelect,
  });
  final DateTime day;
  final List<CalendarEvent> events;
  final (double, double) range;
  final ValueChanged<CalendarEvent>? onSelect;

  @override
  Widget build(BuildContext context) {
    final segments = _segmentsForDay(events, day, range);
    final height = (range.$2 - range.$1) * _hourHeight;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: context.srColors.divider)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            for (var hour = range.$1.ceil(); hour < range.$2; hour++)
              Positioned(
                left: 0,
                right: 0,
                top: (hour - range.$1) * _hourHeight,
                height: 1,
                child: ColoredBox(color: context.srColors.dividerSoft),
              ),
            for (final segment in segments)
              Positioned(
                top: (segment.start - range.$1) * _hourHeight + 2,
                height: ((segment.end - segment.start) * _hourHeight - 4).clamp(
                  20.0,
                  height,
                ),
                left:
                    3 +
                    segment.lane /
                        segment.laneCount *
                        (constraints.maxWidth - 6),
                width: ((constraints.maxWidth - 6) / segment.laneCount).clamp(
                  20.0,
                  constraints.maxWidth,
                ),
                child: _EventChip(
                  event: segment.event,
                  compact: false,
                  onTap: onSelect == null
                      ? null
                      : () => onSelect!(segment.event),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TimeLabels extends StatelessWidget {
  const _TimeLabels({required this.range});
  final (double, double) range;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 52,
    child: Stack(
      children: [
        for (var hour = range.$1.ceil(); hour < range.$2; hour++)
          Positioned(
            right: 7,
            top: (hour - range.$1) * _hourHeight - 5,
            child: Text(
              '${hour.toString().padLeft(2, '0')}:00',
              style: mono(9, color: context.srColors.mutedLight),
            ),
          ),
      ],
    ),
  );
}

class _HorizontalTimeLabels extends StatelessWidget {
  const _HorizontalTimeLabels({required this.range});
  final (double, double) range;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Stack(
      children: [
        for (var hour = range.$1.ceil(); hour <= range.$2.floor(); hour++)
          Positioned(
            left:
                (hour - range.$1) /
                (range.$2 - range.$1) *
                constraints.maxWidth,
            top: 10,
            child: Text(
              '${hour.toString().padLeft(2, '0')}:00',
              style: mono(9, color: context.srColors.mutedLight),
            ),
          ),
      ],
    ),
  );
}

class _FacilityRow extends StatelessWidget {
  const _FacilityRow({
    required this.facility,
    required this.day,
    required this.events,
    required this.range,
    required this.onSelect,
  });
  final String facility;
  final DateTime day;
  final List<CalendarEvent> events;
  final (double, double) range;
  final ValueChanged<CalendarEvent>? onSelect;

  @override
  Widget build(BuildContext context) {
    final segments = _segmentsForDay(events, day, range);
    return SizedBox(
      height: (segments.length * 20 + 14)
          .clamp(54.0, double.infinity)
          .toDouble(),
      child: Row(
        children: [
          SizedBox(
            width: 190,
            child: Container(
              height: double.infinity,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(color: context.srColors.divider),
                  bottom: BorderSide(color: context.srColors.dividerSoft),
                ),
              ),
              child: Text(
                facility,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sans(11.5, w: 500, color: context.srColors.ink2),
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: context.srColors.dividerSoft),
                  ),
                ),
                child: Stack(
                  children: [
                    for (
                      var hour = range.$1.ceil();
                      hour <= range.$2.floor();
                      hour++
                    )
                      Positioned(
                        left:
                            (hour - range.$1) /
                            (range.$2 - range.$1) *
                            constraints.maxWidth,
                        top: 0,
                        bottom: 0,
                        width: 1,
                        child: ColoredBox(color: context.srColors.dividerSoft),
                      ),
                    for (final segment in segments)
                      Positioned(
                        top: 6 + segment.lane * 20,
                        height: 18,
                        left:
                            (segment.start - range.$1) /
                                (range.$2 - range.$1) *
                                constraints.maxWidth +
                            2,
                        width:
                            ((segment.end - segment.start) /
                                        (range.$2 - range.$1) *
                                        constraints.maxWidth -
                                    4)
                                .clamp(24.0, constraints.maxWidth),
                        child: _EventChip(
                          event: segment.event,
                          compact: true,
                          onTap: onSelect == null
                              ? null
                              : () => onSelect!(segment.event),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventChip extends StatelessWidget {
  const _EventChip({
    required this.event,
    required this.compact,
    required this.onTap,
  });
  final CalendarEvent event;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: '${event.effectiveStatusLabel}: ${event.facility}',
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 4 : 6,
          vertical: compact ? 2 : 4,
        ),
        decoration: BoxDecoration(
          color: event.state.background,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: event.state.border),
        ),
        child: Text(
          compact
              ? '${event.startsAt.hour.toString().padLeft(2, '0')}:${event.startsAt.minute.toString().padLeft(2, '0')} ${event.eventChipLabel}'
              : event.eventChipLabel,
          maxLines: compact ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: sans(
            compact ? 8.7 : 10,
            w: 600,
            color: event.state.foreground,
          ),
        ),
      ),
    ),
  );
}

class _EventDetails extends StatelessWidget {
  const _EventDetails({
    required this.event,
    required this.onClose,
    required this.onOpenRequest,
  });
  final CalendarEvent event;
  final VoidCallback onClose;
  final VoidCallback? onOpenRequest;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text('Reservation details', style: sans(13.5, w: 600)),
          ),
          SrIconButton(
            icon: Icons.close_rounded,
            fontSize: 13,
            tooltip: 'Close reservation details',
            onPressed: onClose,
          ),
        ],
      ),
      const SizedBox(height: 15),
      _StatusBadge(event: event),
      const SizedBox(height: 12),
      Text(event.facility, style: sans(16, w: 600, tracking: -.015)),
      if (event.building.isNotEmpty || event.room.isNotEmpty) ...[
        const SizedBox(height: 3),
        Text(
          [
            event.building,
            event.room,
          ].where((part) => part.isNotEmpty).join(' · '),
          style: sans(11.5, color: context.srColors.ink4),
        ),
      ],
      const SizedBox(height: 17),
      _DetailRow(
        label: 'When',
        value: '${formatCampusDate(event.startsAt)} · ${event.timeLabel}',
      ),
      _DetailRow(label: 'Requester', value: event.requester),
      if (event.organization.isNotEmpty)
        _DetailRow(label: 'Organization', value: event.organization),
      if (event.headcount > 0)
        _DetailRow(label: 'Headcount', value: '${event.headcount} people'),
      _DetailRow(label: 'Lifecycle', value: event.lifecycle.label),
      if (event.recurrenceLabel != null)
        _DetailRow(label: 'Series', value: event.recurrenceLabel!),
      const SizedBox(height: 14),
      Text('Purpose', style: keyLabel),
      const SizedBox(height: 5),
      Text(
        event.purpose,
        style: sans(12, height: 1.55, color: context.srColors.ink3),
      ),
      const SizedBox(height: 20),
      if (onOpenRequest != null)
        SrButton(
          label: 'Open reservation',
          kind: SrButtonKind.primary,
          expand: true,
          onPressed: onOpenRequest,
        )
      else
        Text(
          'This imported booking has no reservation record to open.',
          style: sans(11, height: 1.5, color: context.srColors.muted),
        ),
    ],
  );
}

class _MobileDetails extends StatelessWidget {
  const _MobileDetails({
    required this.event,
    required this.onClose,
    required this.onOpenRequest,
  });
  final CalendarEvent event;
  final VoidCallback onClose;
  final VoidCallback? onOpenRequest;
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: GestureDetector(
          onTap: onClose,
          child: ColoredBox(color: context.srColors.scrim),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        top: 70,
        child: Material(
          color: context.srColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
            child: _EventDetails(
              event: event,
              onClose: onClose,
              onOpenRequest: onOpenRequest,
            ),
          ),
        ),
      ),
    ],
  );
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.event});
  final CalendarEvent event;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: event.state.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: event.state.border),
      ),
      child: Text(
        event.effectiveStatusLabel,
        style: sans(10.5, w: 600, color: event.state.foreground),
      ),
    ),
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: keyLabel),
        const SizedBox(height: 2),
        Text(value, style: sans(12, height: 1.4, color: context.srColors.ink3)),
      ],
    ),
  );
}

class _EmptyCalendar extends StatelessWidget {
  const _EmptyCalendar({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 44),
    child: Center(
      child: Text(message, style: sans(12, color: context.srColors.ink4)),
    ),
  );
}

class _TimedSegment {
  const _TimedSegment(
    this.event,
    this.start,
    this.end,
    this.lane,
    this.laneCount,
  );
  final CalendarEvent event;
  final double start;
  final double end;
  final int lane;
  final int laneCount;
}

List<_TimedSegment> _segmentsForDay(
  List<CalendarEvent> events,
  DateTime day,
  (double, double) range,
) {
  final startOfDay = DateTime(day.year, day.month, day.day);
  final endOfDay = startOfDay.add(const Duration(days: 1));
  final candidates = [
    for (final event in events)
      if (event.overlapsDay(day))
        (
          event,
          _clockOf(
            event.startsAt.isAfter(startOfDay) ? event.startsAt : startOfDay,
          ).clamp(range.$1, range.$2),
          _clockOf(
            event.endsAt.isBefore(endOfDay) ? event.endsAt : endOfDay,
          ).clamp(range.$1, range.$2),
        ),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  final laneEnds = <double>[];
  final assigned = <(CalendarEvent, double, double, int)>[];
  for (final item in candidates) {
    var lane = laneEnds.indexWhere((end) => end <= item.$2);
    if (lane < 0) {
      lane = laneEnds.length;
      laneEnds.add(item.$3);
    } else {
      laneEnds[lane] = item.$3;
    }
    assigned.add((item.$1, item.$2, item.$3, lane));
  }
  return [
    for (final item in assigned)
      _TimedSegment(item.$1, item.$2, item.$3, item.$4, laneEnds.length),
  ];
}

(double, double) _hourRange(Iterable<CalendarEvent> events) {
  var start = _minimumStartHour.toDouble();
  var end = _minimumEndHour.toDouble();
  for (final event in events) {
    start = start > _clockOf(event.startsAt) ? _clockOf(event.startsAt) : start;
    final spansMidnight =
        event.startsAt.year != event.endsAt.year ||
        event.startsAt.month != event.endsAt.month ||
        event.startsAt.day != event.endsAt.day;
    if (spansMidnight) start = 0;
    final eventEnd = spansMidnight ? 24.0 : _clockOf(event.endsAt);
    end = end < eventEnd ? eventEnd : end;
  }
  return (
    start.floorToDouble().clamp(0, 23).toDouble(),
    end.ceilToDouble().clamp(1, 24).toDouble(),
  );
}

double _clockOf(DateTime value) => value.hour + value.minute / 60;

DateTime _weekStart(DateTime day) {
  final date = DateTime(day.year, day.month, day.day);
  return date.subtract(Duration(days: date.weekday - 1));
}

bool _isToday(DateTime day) {
  final now = campusNow();
  return day.year == now.year && day.month == now.month && day.day == now.day;
}
