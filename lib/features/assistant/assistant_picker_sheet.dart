library;

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../model/facility.dart';
import '../../model/payment.dart';
import '../../theme/sr_theme.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/sr_controls.dart';
import 'assistant_availability.dart';
import 'assistant_controller.dart';

enum AssistantPickerResultAction { select, retry }

class AssistantPickerResult {
  const AssistantPickerResult._({
    required this.kind,
    required this.action,
    this.facility,
    this.date,
    this.startHour,
    this.endHour,
  });

  final AssistantPickerKind kind;
  final AssistantPickerResultAction action;
  final Facility? facility;
  final DateTime? date;
  final double? startHour;
  final double? endHour;

  factory AssistantPickerResult.retry(AssistantPickerKind kind) =>
      AssistantPickerResult._(
        kind: kind,
        action: AssistantPickerResultAction.retry,
      );

  factory AssistantPickerResult.facility(Facility facility) =>
      AssistantPickerResult._(
        kind: AssistantPickerKind.facility,
        action: AssistantPickerResultAction.select,
        facility: facility,
      );

  factory AssistantPickerResult.date(DateTime date) => AssistantPickerResult._(
    kind: AssistantPickerKind.date,
    action: AssistantPickerResultAction.select,
    date: date,
  );

  factory AssistantPickerResult.time(double startHour, double endHour) =>
      AssistantPickerResult._(
        kind: AssistantPickerKind.time,
        action: AssistantPickerResultAction.select,
        startHour: startHour,
        endHour: endHour,
      );
}

Future<AssistantPickerResult?> showAssistantPickerSheet(
  BuildContext context, {
  required AssistantPickerPrompt prompt,
  required AppState state,
}) {
  final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
  return showModalBottomSheet<AssistantPickerResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: context.srColors.surface,
    constraints: const BoxConstraints(maxWidth: 640),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(compact ? 20 : 18),
      ),
    ),
    builder: (context) => _AssistantPickerSheet(prompt: prompt, state: state),
  );
}

enum _PickerView { recommendations, browseFacilities, otherDate, otherTime }

class _AssistantPickerSheet extends StatefulWidget {
  const _AssistantPickerSheet({required this.prompt, required this.state});

  final AssistantPickerPrompt prompt;
  final AppState state;

  @override
  State<_AssistantPickerSheet> createState() => _AssistantPickerSheetState();
}

class _AssistantPickerSheetState extends State<_AssistantPickerSheet> {
  _PickerView _view = _PickerView.recommendations;
  final _search = TextEditingController();
  double? _startHour;
  double? _endHour;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = MediaQuery.sizeOf(context).height * .75;
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 16 : 18,
        10,
        compact ? 16 : 18,
        18 + keyboardInset,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: context.srColors.border,
                  borderRadius: BorderRadius.circular(100),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.prompt.title,
                        style: sans(compact ? 15 : 17, w: 600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.prompt.subtitle,
                        style: sans(
                          12,
                          height: 1.45,
                          color: context.srColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SrIconButton(
                  icon: Icons.close_rounded,
                  tooltip: 'Close picker',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: _body(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    switch (widget.prompt.status) {
      case AssistantPickerStatus.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(child: CircularProgressIndicator()),
        );
      case AssistantPickerStatus.error:
        return _StatusPanel(
          icon: Icons.wifi_off_rounded,
          title: 'Live schedule unavailable',
          message:
              widget.prompt.error ??
              'Please retry so I can scan the current schedule.',
          actionLabel: 'Retry',
          onAction: () => Navigator.of(
            context,
          ).pop(AssistantPickerResult.retry(widget.prompt.kind)),
        );
      case AssistantPickerStatus.empty:
        return _StatusPanel(
          icon: Icons.event_busy_rounded,
          title: 'No matching options',
          message:
              widget.prompt.error ??
              'Try changing the facility, date, or attendee count.',
          actionLabel: 'Retry',
          onAction: () => Navigator.of(
            context,
          ).pop(AssistantPickerResult.retry(widget.prompt.kind)),
        );
      case AssistantPickerStatus.ready:
        return switch (widget.prompt) {
          FacilityPickerPrompt prompt => _facilityBody(context, prompt),
          DatePickerPrompt prompt => _dateBody(context, prompt),
          TimePickerPrompt prompt => _timeBody(context, prompt),
        };
    }
  }

  Widget _facilityBody(BuildContext context, FacilityPickerPrompt prompt) {
    if (_view == _PickerView.browseFacilities) {
      final query = _search.text.trim().toLowerCase();
      final matches = [
        for (final facility in prompt.allMatches)
          if (query.isEmpty ||
              facility.name.toLowerCase().contains(query) ||
              facility.building.toLowerCase().contains(query) ||
              facility.room.toLowerCase().contains(query) ||
              facility.category.toLowerCase().contains(query) ||
              facility.amenities.any(
                (amenity) => amenity.toLowerCase().contains(query),
              ))
            facility,
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BackRow(
            label: 'Recommendations',
            onBack: () => setState(() => _view = _PickerView.recommendations),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'Search facilities',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          for (final facility in matches)
            _FacilityOption(
              facility: facility,
              state: widget.state,
              onTap: () => Navigator.of(
                context,
              ).pop(AssistantPickerResult.facility(facility)),
            ),
          if (matches.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'No facilities match that search.',
                style: sans(12, color: context.srColors.textMuted),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final facility in prompt.recommended)
          _FacilityOption(
            facility: facility,
            state: widget.state,
            onTap: () => Navigator.of(
              context,
            ).pop(AssistantPickerResult.facility(facility)),
          ),
        _WideActionButton(
          icon: Icons.manage_search_rounded,
          label: 'Browse all facilities',
          onTap: () => setState(() => _view = _PickerView.browseFacilities),
        ),
      ],
    );
  }

  Widget _dateBody(BuildContext context, DatePickerPrompt prompt) {
    if (_view == _PickerView.otherDate) {
      final initialDate = prompt.availableDays.isNotEmpty
          ? (prompt.availableDays.toList()..sort()).first
          : prompt.firstDate;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BackRow(
            label: 'Recommended dates',
            onBack: () => setState(() => _view = _PickerView.recommendations),
          ),
          const SizedBox(height: 10),
          CalendarDatePicker(
            initialDate: initialDate,
            firstDate: prompt.firstDate,
            lastDate: prompt.lastDate,
            selectableDayPredicate: (day) => prompt.availableDays.contains(
              DateTime(day.year, day.month, day.day),
            ),
            onDateChanged: (date) =>
                Navigator.of(context).pop(AssistantPickerResult.date(date)),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final day in prompt.recommended)
          _DateOption(
            day: day,
            onTap: () =>
                Navigator.of(context).pop(AssistantPickerResult.date(day.day)),
          ),
        _WideActionButton(
          icon: Icons.calendar_month_rounded,
          label: 'Other date',
          onTap: () => setState(() => _view = _PickerView.otherDate),
        ),
      ],
    );
  }

  Widget _timeBody(BuildContext context, TimePickerPrompt prompt) {
    if (_view == _PickerView.otherTime) return _customTimeBody(context, prompt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final slot in prompt.recommended)
          _TimeOption(
            slot: slot,
            onTap: () => Navigator.of(
              context,
            ).pop(AssistantPickerResult.time(slot.startHour, slot.endHour)),
          ),
        _WideActionButton(
          icon: Icons.schedule_rounded,
          label: 'Other time',
          onTap: () => setState(() {
            _view = _PickerView.otherTime;
            _startHour ??= prompt.recommended.isEmpty
                ? null
                : prompt.recommended.first.startHour;
            _endHour ??= _startHour == null
                ? null
                : _startHour! + prompt.requiredDurationHours;
          }),
        ),
      ],
    );
  }

  Widget _customTimeBody(BuildContext context, TimePickerPrompt prompt) {
    final starts = _halfHours(
      prompt.openHour.toDouble(),
      prompt.closeHour.toDouble(),
    );
    final ends = _halfHours(
      prompt.openHour.toDouble() + .5,
      prompt.closeHour.toDouble(),
    );
    final start = _startHour;
    final end = _endHour;
    final String statusText;
    final VoidCallback? useTime;
    if (start == null || end == null) {
      statusText = 'Choose a start and end time.';
      useTime = null;
    } else {
      final problem = _customTimeProblem(prompt, start, end);
      if (problem == null) {
        statusText = 'Available for ${((end - start) * 60).round()} minutes.';
        useTime = () =>
            Navigator.of(context).pop(AssistantPickerResult.time(start, end));
      } else {
        statusText = problem;
        useTime = null;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BackRow(
          label: 'Recommended times',
          onBack: () => setState(() => _view = _PickerView.recommendations),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<double>(
                initialValue: _startHour,
                decoration: const InputDecoration(
                  labelText: 'Start',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final hour in starts)
                    DropdownMenuItem<double>(
                      value: hour,
                      enabled: _startSelectable(prompt, hour),
                      child: Text(formatClockHour(hour)),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _startHour = value;
                  if (value != null &&
                      (_endHour == null || _endHour! <= value)) {
                    final proposedEnd = value + prompt.requiredDurationHours;
                    _endHour = proposedEnd <= prompt.closeHour
                        ? proposedEnd
                        : null;
                  }
                }),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<double>(
                initialValue: _endHour,
                decoration: const InputDecoration(
                  labelText: 'End',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final hour in ends)
                    DropdownMenuItem<double>(
                      value: hour,
                      enabled:
                          start != null &&
                          _validCustomTime(prompt, start, hour),
                      child: Text(formatClockHour(hour)),
                    ),
                ],
                onChanged: (value) => setState(() => _endHour = value),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          statusText,
          style: sans(
            12,
            color: useTime != null
                ? context.srColors.greenDeep
                : context.srColors.amberInk,
          ),
        ),
        const SizedBox(height: 12),
        SrButton(
          label: 'Use this time',
          kind: SrButtonKind.primary,
          onPressed: useTime,
        ),
      ],
    );
  }

  List<double> _halfHours(double start, double end) {
    final values = <double>[];
    var hour = start;
    while (hour <= end) {
      values.add(hour);
      hour += .5;
    }
    return values;
  }

  bool _startSelectable(TimePickerPrompt prompt, double start) {
    if (start < prompt.openHour || start >= prompt.closeHour) return false;
    final now = campusNow();
    final sameDay =
        now.year == prompt.day.year &&
        now.month == prompt.day.month &&
        now.day == prompt.day.day;
    if (!sameDay) return true;
    final nowHour = now.hour + now.minute / 60;
    return start >= (nowHour * 2).ceil() / 2;
  }

  bool _validCustomTime(TimePickerPrompt prompt, double start, double end) =>
      _customTimeProblem(prompt, start, end) == null;

  String? _customTimeProblem(
    TimePickerPrompt prompt,
    double start,
    double end,
  ) {
    if (!_startSelectable(prompt, start)) {
      return 'Start time is outside the bookable window.';
    }
    if (end <= start) return 'End time must be after the start.';
    if (end > prompt.closeHour) return 'End time must be before closing.';
    if (((end - start) * 60).round() > prompt.maxDurationMinutes) {
      return 'That is longer than this facility allows.';
    }
    final bufferHours = (2 * prompt.bufferMinutes) / 60;
    final clashes = prompt.busyWindows.any(
      (busy) =>
          busy.startHour - bufferHours < end &&
          start < busy.endHour + bufferHours,
    );
    if (clashes) return 'That range overlaps a held or booked reservation.';
    return null;
  }
}

class _FacilityOption extends StatelessWidget {
  const _FacilityOption({
    required this.facility,
    required this.state,
    required this.onTap,
  });

  final Facility facility;
  final AppState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rate = facility.hourlyRateCentavosFor(
      state.userAccount.pricingAudience,
    );
    return _OptionShell(
      key: ValueKey(assistantFacilityOptionId(facility)),
      semanticLabel: 'Choose ${facility.name}',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(facility.name, style: sans(13, w: 600)),
          const SizedBox(height: 3),
          Text(
            facility.whereLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sans(11, color: context.srColors.textMuted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              SrPill(
                label: '${facility.capacity} seats',
                background: context.srColors.dividerSoft,
                foreground: context.srColors.ink3,
              ),
              SrPill(
                label: facility.hours,
                background: context.srColors.dividerSoft,
                foreground: context.srColors.ink3,
                monospace: true,
              ),
              SrPill(
                label: rate == 0
                    ? 'Included'
                    : '${pesoFromCentavos(rate * 2)} / 2h',
                background: context.srColors.primaryTint,
                foreground: context.srColors.primaryDeep,
              ),
              for (final amenity in facility.amenities.take(3))
                SrPill(
                  label: amenity,
                  background: context.srColors.primaryTint2,
                  foreground: context.srColors.primaryDeep,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DateOption extends StatelessWidget {
  const _DateOption({required this.day, required this.onTap});

  final AvailableBookingDay day;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _OptionShell(
    key: ValueKey(assistantDateOptionId(day.day)),
    semanticLabel: 'Choose ${formatCampusDate(day.day)}',
    onTap: onTap,
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(formatCampusDate(day.day), style: sans(13, w: 600)),
              const SizedBox(height: 3),
              Text(
                'First slot ${day.firstAvailableSlot.label}',
                style: sans(11, color: context.srColors.textMuted),
              ),
            ],
          ),
        ),
        SrPill(
          label: 'Available',
          background: context.srColors.greenTint,
          foreground: context.srColors.greenDeep,
          dot: context.srColors.greenDeep,
        ),
      ],
    ),
  );
}

class _TimeOption extends StatelessWidget {
  const _TimeOption({required this.slot, required this.onTap});

  final FreeSlot slot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _OptionShell(
    key: ValueKey(assistantTimeOptionId(slot.startHour, slot.endHour)),
    semanticLabel: 'Choose ${slot.label}',
    onTap: onTap,
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(slot.label, style: sans(14, w: 600)),
              const SizedBox(height: 3),
              Text(
                '${((slot.endHour - slot.startHour) * 60).round()} minutes',
                style: sans(11, color: context.srColors.textMuted),
              ),
            ],
          ),
        ),
        Icon(Icons.chevron_right_rounded, color: context.srColors.textMuted),
      ],
    ),
  );
}

class _OptionShell extends StatelessWidget {
  const _OptionShell({
    super.key,
    required this.semanticLabel,
    required this.onTap,
    required this.child,
  });

  final String semanticLabel;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semanticLabel,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Ink(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.srColors.surfaceSubtle,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.srColors.border),
            ),
            child: child,
          ),
        ),
      ),
    ),
  );
}

class _WideActionButton extends StatelessWidget {
  const _WideActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: OutlinedButton.icon(
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
    ),
  );
}

class _BackRow extends StatelessWidget {
  const _BackRow({required this.label, required this.onBack});

  final String label;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      onPressed: onBack,
      icon: const Icon(Icons.arrow_back_rounded, size: 18),
      label: Text(label),
    ),
  );
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      children: [
        Icon(icon, size: 28, color: context.srColors.textMuted),
        const SizedBox(height: 8),
        Text(title, style: sans(13, w: 600), textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(
          message,
          style: sans(12, height: 1.45, color: context.srColors.textMuted),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 14),
        SrButton(
          label: actionLabel,
          kind: SrButtonKind.primary,
          onPressed: onAction,
        ),
      ],
    ),
  );
}
