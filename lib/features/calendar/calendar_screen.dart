import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../model/calendar_event.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/sr_controls.dart';

const _minimumStartHour = 7;
const _minimumEndHour = 20;
const _hourHeight = 48.0;

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final compact = MediaQuery.sizeOf(context).width < SR.tabletMin;
    final selected = state.selectedCalendarEvent;
    final calendar = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(state: state, search: _search, compact: compact),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 14 : 20,
              14,
              compact ? 14 : 20,
              24,
            ),
            child: _CalendarBody(state: state),
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
                onClose: () => state.selectCalendarEvent(null),
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
              decoration: const BoxDecoration(
                color: SR.surface,
                border: Border(left: BorderSide(color: SR.border)),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
                child: _EventDetails(
                  event: selected,
                  onClose: () => state.selectCalendarEvent(null),
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

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.state,
    required this.search,
    required this.compact,
  });

  final AppState state;
  final TextEditingController search;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.fromLTRB(compact ? 14 : 20, 10, compact ? 14 : 20, 10),
    decoration: const BoxDecoration(
      color: SR.surface,
      border: Border(bottom: BorderSide(color: SR.border)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: SR.dividerSoft,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final mode in CalendarViewMode.values)
                    _ModeTab(
                      label: mode.label,
                      selected: state.calendarViewMode == mode,
                      onTap: () => state.setCalendarViewMode(mode),
                    ),
                ],
              ),
            ),
            SrIconButton(
              icon: Icons.chevron_left_rounded,
              fontSize: 14,
              tooltip: 'Previous ${state.calendarViewMode.label.toLowerCase()}',
              onPressed: () => state.navigateCalendar(-1),
            ),
            SrButton(
              label: _rangeLabel(state),
              dense: true,
              kind: SrButtonKind.ghost,
              onPressed: state.goToCalendarToday,
              tooltip: 'Go to today',
            ),
            SrIconButton(
              icon: Icons.chevron_right_rounded,
              fontSize: 14,
              tooltip: 'Next ${state.calendarViewMode.label.toLowerCase()}',
              onPressed: () => state.navigateCalendar(1),
            ),
            SrButton(
              label: 'Today',
              dense: true,
              onPressed: state.goToCalendarToday,
            ),
          ],
        ),
        const SizedBox(height: 9),
        FilterBar(
          count: '${state.visibleCalendarEvents.length} shown',
          children: [
            SizedBox(
              width: compact ? 200 : 240,
              child: FilterSelect(
                value: state.calendarFacilityFilter,
                items: state.calendarFacilities,
                semanticLabel: 'Filter calendar by facility',
                onChanged: state.setCalendarFacilityFilter,
              ),
            ),
            FilterSearch(
              controller: search,
              placeholder: 'Search reservations',
              width: compact ? 210 : 260,
              onChanged: state.setCalendarQuery,
            ),
          ],
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final status in CalendarEventState.values)
              FilterPill(
                label: status.label,
                selected: state.calendarStates.contains(status),
                onTap: () => state.toggleCalendarState(status),
              ),
          ],
        ),
      ],
    ),
  );

  String _rangeLabel(AppState state) => switch (state.calendarViewMode) {
    CalendarViewMode.month =>
      '${monthNames[state.calendarAnchor.month - 1]} ${state.calendarAnchor.year}',
    CalendarViewMode.week =>
      '${formatCampusDate(_weekStart(state.calendarAnchor))} – ${formatCampusDate(_weekStart(state.calendarAnchor).add(const Duration(days: 6)))}',
    CalendarViewMode.day => formatCampusDate(state.calendarAnchor),
  };
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: SR.stateChange,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? SR.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          boxShadow: selected ? SR.cardShadow : null,
        ),
        child: Text(
          label,
          style: sans(11.5, w: 500, color: selected ? SR.ink : SR.ink4),
        ),
      ),
    ),
  );
}

class _CalendarBody extends StatelessWidget {
  const _CalendarBody({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => switch (state.calendarViewMode) {
    CalendarViewMode.month => _MonthView(state: state),
    CalendarViewMode.week => _WeekView(state: state),
    CalendarViewMode.day => _DayView(state: state),
  };
}

class _MonthView extends StatelessWidget {
  const _MonthView({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(
      state.calendarAnchor.year,
      state.calendarAnchor.month,
    );
    final start = first.subtract(Duration(days: first.weekday - 1));
    final events = state.visibleCalendarEvents;
    return Scrollbar(
      child: SingleChildScrollView(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 760.0;
            final narrow = availableWidth < 760;
            final grid = SizedBox(
              width: narrow ? 760 : availableWidth,
              child: _grid(start, events, narrow ? 104 : 118),
            );
            return narrow
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: grid,
                  )
                : grid;
          },
        ),
      ),
    );
  }

  Widget _grid(DateTime start, List<CalendarEvent> events, double height) =>
      Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: SR.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: SR.border),
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
                      decoration: const BoxDecoration(
                        border: Border(bottom: BorderSide(color: SR.hairline)),
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
                          currentMonth: state.calendarAnchor.month,
                          events: [
                            for (final event in events)
                              if (event.overlapsDay(
                                start.add(Duration(days: week * 7 + index)),
                              ))
                                event,
                          ],
                          onSelectDay: () => state.selectCalendarDate(
                            start.add(Duration(days: week * 7 + index)),
                            mode: CalendarViewMode.day,
                          ),
                          onSelectEvent: (event) =>
                              state.selectCalendarEvent(event.id),
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
  final ValueChanged<CalendarEvent> onSelectEvent;

  @override
  Widget build(BuildContext context) {
    final outside = day.month != currentMonth;
    final shown = events.take(2).toList();
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: const BoxDecoration(
        border: Border(
          right: BorderSide(color: SR.divider),
          bottom: BorderSide(color: SR.divider),
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
                  color: _isToday(day) ? SR.blue : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${day.day}',
                  style: mono(
                    10,
                    w: 500,
                    color: _isToday(day)
                        ? SR.surface
                        : (outside ? SR.mutedLight : SR.ink3),
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
              onTap: () => onSelectEvent(event),
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
                  style: sans(9.5, w: 500, color: SR.blue),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WeekView extends StatelessWidget {
  const _WeekView({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final start = _weekStart(state.calendarAnchor);
    final days = [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
    final events = state.visibleCalendarEvents;
    final range = _hourRange(
      events.where(
        (event) =>
            event.startsAt.isBefore(start.add(const Duration(days: 7))) &&
            event.endsAt.isAfter(start),
      ),
    );
    final height = (range.$2 - range.$1) * _hourHeight;
    return Scrollbar(
      child: SingleChildScrollView(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final content = _weekGrid(days, events, range, height);
            return constraints.maxWidth < 820
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(width: 900, child: content),
                  )
                : content;
          },
        ),
      ),
    );
  }

  Widget _weekGrid(
    List<DateTime> days,
    List<CalendarEvent> events,
    (double, double) range,
    double height,
  ) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: SR.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SR.border),
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
                  decoration: const BoxDecoration(
                    border: Border(
                      left: BorderSide(color: SR.divider),
                      bottom: BorderSide(color: SR.hairline),
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
                        style: mono(9.5, color: SR.muted),
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
                    onSelect: (event) => state.selectCalendarEvent(event.id),
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
  const _DayView({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final day = DateTime(
      state.calendarAnchor.year,
      state.calendarAnchor.month,
      state.calendarAnchor.day,
    );
    final events = [
      for (final event in state.visibleCalendarEvents)
        if (event.overlapsDay(day)) event,
    ];
    final facilities = state.calendarFacilityFilter == 'All facilities'
        ? state.scheduleFacilities
        : [state.calendarFacilityFilter];
    final range = _hourRange(events);
    return Scrollbar(
      child: SingleChildScrollView(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final grid = _dayGrid(day, facilities, events, range);
            return constraints.maxWidth < 760
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(width: 760, child: grid),
                  )
                : grid;
          },
        ),
      ),
    );
  }

  Widget _dayGrid(
    DateTime day,
    List<String> facilities,
    List<CalendarEvent> events,
    (double, double) range,
  ) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: SR.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SR.border),
    ),
    child: Column(
      children: [
        Container(
          height: 36,
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: SR.hairline)),
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
              onSelect: (event) => state.selectCalendarEvent(event.id),
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
  final ValueChanged<CalendarEvent> onSelect;

  @override
  Widget build(BuildContext context) {
    final segments = _segmentsForDay(events, day, range);
    final height = (range.$2 - range.$1) * _hourHeight;
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: SR.divider)),
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
                child: const ColoredBox(color: SR.dividerSoft),
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
                  onTap: () => onSelect(segment.event),
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
              style: mono(9, color: SR.mutedLight),
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
              style: mono(9, color: SR.mutedLight),
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
  final ValueChanged<CalendarEvent> onSelect;

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
              decoration: const BoxDecoration(
                border: Border(
                  right: BorderSide(color: SR.divider),
                  bottom: BorderSide(color: SR.dividerSoft),
                ),
              ),
              child: Text(
                facility,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sans(11.5, w: 500, color: SR.ink2),
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Container(
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: SR.dividerSoft)),
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
                        child: const ColoredBox(color: SR.dividerSoft),
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
                          onTap: () => onSelect(segment.event),
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
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '${event.state.label}: ${event.facility}, ${event.requester}',
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
              ? '${event.startsAt.hour.toString().padLeft(2, '0')}:${event.startsAt.minute.toString().padLeft(2, '0')} ${event.facility}'
              : '${event.facility} · ${event.requester}',
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
          style: sans(11.5, color: SR.ink4),
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
      Text(event.purpose, style: sans(12, height: 1.55, color: SR.ink3)),
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
          style: sans(11, height: 1.5, color: SR.muted),
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
          child: const ColoredBox(color: Color(0x6B10141A)),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        top: 70,
        child: Material(
          color: SR.surface,
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
        event.state.label,
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
        Text(value, style: sans(12, height: 1.4, color: SR.ink3)),
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
      child: Text(message, style: sans(12, color: SR.ink4)),
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
