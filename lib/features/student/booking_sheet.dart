import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
import '../../model/account.dart';
import '../../model/amenity_request.dart';
import '../../model/facility.dart';
import '../../model/loyalty.dart';
import '../../model/notice.dart';
import '../../model/reservation.dart';
import '../../model/payment.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/amenity_request_field.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';
import 'facility_preview.dart';

import '../../theme/sr_theme.dart';

Future<void> showBookingSheet(
  BuildContext context, {
  required AppState state,
  required Facility facility,
}) {
  if (MediaQuery.sizeOf(context).width < SR.tabletMin) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _MobileFacilityPage(state: state, facility: facility),
      ),
    );
  }

  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x7010141A),
    builder: (_) => _BookingSheet(state: state, facility: facility),
  );
}

class _MobileFacilityPage extends StatelessWidget {
  const _MobileFacilityPage({required this.state, required this.facility});

  final AppState state;
  final Facility facility;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.srColors.surface,
    appBar: AppBar(
      backgroundColor: context.srColors.surface,
      foregroundColor: context.srColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: const BackButton(),
      titleSpacing: 0,
      title: Text(
        facility.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sans(15, w: 600, tracking: -.01),
      ),
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: context.srColors.border),
      ),
    ),
    body: SafeArea(
      top: false,
      child: _BookingSheet(state: state, facility: facility, fullPage: true),
    ),
  );
}

class _BookingSheet extends StatefulWidget {
  const _BookingSheet({
    required this.state,
    required this.facility,
    this.fullPage = false,
  });

  final AppState state;
  final Facility facility;
  final bool fullPage;

  @override
  State<_BookingSheet> createState() => _BookingSheetState();
}

class _BookingSheetState extends State<_BookingSheet> {
  late final List<DateTime> _dateValues;
  late final List<String> _dates;
  late String _date;
  late String _start;
  late String _end;
  final _heads = TextEditingController(text: '20');
  final _purpose = TextEditingController();
  bool _attempted = false;
  bool _submitting = false;
  bool _weekly = false;
  int _occurrenceCount = 2;
  final List<ReservationUpload> _attachments = [];
  final Set<String> _amenities = <String>{};
  BackendReservationQuote? _serverQuote;
  String? _quoteError;
  bool _quoteLoading = false;
  String? _selectedVoucherId;
  List<Map<String, dynamic>> _ownOverlaps = const [];
  bool _termsAccepted = false;
  Timer? _quoteTimer;
  int _quoteRequest = 0;
  int _selectedPhoto = 0;

  Facility get facility => widget.facility;

  @override
  void initState() {
    super.initState();
    _dateValues = _availableDates();
    _dates = [for (final value in _dateValues) _dateLabel(value)];
    _date = _dates.first;
    final slots = _times;
    _start = slots.first;
    _end = slots.length > 2 ? slots[2] : slots.last;
    _heads.addListener(_scheduleQuote);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.state.shouldRefreshLoyaltyForCurrentUser) {
        unawaited(widget.state.refreshLoyalty());
      }
      _scheduleQuote();
    });
  }

  @override
  void dispose() {
    _heads.removeListener(_scheduleQuote);
    _heads.dispose();
    _purpose.dispose();
    _quoteTimer?.cancel();
    super.dispose();
  }

  List<String> get _allSlots => [
    for (
      var minutes = facility.openHour * 60;
      minutes <= facility.closeHour * 60;
      minutes += 30
    )
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
          '${(minutes % 60).toString().padLeft(2, '0')}',
  ];

  List<String> _slotsFor(DateTime date) =>
      bookableSlots(_allSlots, date, campusNow());

  /// Falls back to the full day when today has nothing left, so the dropdowns
  /// keep a valid value; [_error] blocks the submit in that case.
  List<String> get _times {
    final slots = _slotsFor(_selectedDate);
    return slots.length >= 2 ? slots : _allSlots;
  }

  List<DateTime> _availableDates() {
    final today = campusNow();
    final start = DateTime(today.year, today.month, today.day);
    final values = <DateTime>[];
    for (var offset = 0; offset <= facility.advanceBookingDays; offset++) {
      final date = start.add(Duration(days: offset));
      // A day needs both a start and a later end to be bookable.
      if (facility.opensOn(date) && _slotsFor(date).length >= 2) {
        values.add(date);
      }
    }
    return values.isEmpty ? [start] : values;
  }

  /// Re-anchors the time selection after the date changes: today's list is
  /// shorter than a future day's, and `DropdownButton` asserts that its value
  /// is present in its items.
  void _clampTimes() {
    final slots = _times;
    if (!slots.contains(_start)) _start = slots.first;
    var startIndex = slots.indexOf(_start);
    if (slots.length >= 2 && startIndex == slots.length - 1) {
      startIndex = slots.length - 2;
      _start = slots[startIndex];
    }
    if (!slots.contains(_end) || slots.indexOf(_end) <= startIndex) {
      _end = slots[(startIndex + 2).clamp(startIndex + 1, slots.length - 1)];
    }
  }

  static String _dateLabel(DateTime date) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
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
    return '${weekdays[date.weekday - 1]} ${date.day} '
        '${months[date.month - 1]}';
  }

  DateTime get _selectedDate => _dateValues[_dates.indexOf(_date)];

  DateTime _at(String clock, [int weekOffset = 0]) {
    final parts = clock.split(':').map(int.parse).toList();
    final date = _selectedDate.add(Duration(days: weekOffset * 7));
    return campusInstant(
      DateTime(date.year, date.month, date.day, parts[0], parts[1]),
    );
  }

  double _hour(String hhmm) {
    final parts = hhmm.split(':');
    return (int.tryParse(parts.first) ?? 0) +
        (int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0) / 60;
  }

  double get _duration => _hour(_end) - _hour(_start);

  int get _headcount => int.tryParse(_heads.text.trim()) ?? 0;

  List<Booking> get _clashes => [
    for (final b in widget.state.bookings)
      if (b.facility == facility.name &&
          b.date == _date &&
          b.overlaps(_hour(_start), _hour(_end)))
        b,
  ];

  bool get _overCapacity => _headcount > facility.capacity;

  String? get _error {
    if (!_attempted) return null;
    if (widget.state.userAccount.status == AccountStatus.suspended) {
      return widget.state.userAccount.suspendReason ??
          'This account is suspended and cannot submit new requests.';
    }
    if (_duration <= 0) return 'The end time has to be after the start time.';
    if (!_at(_start).isAfter(DateTime.now().toUtc())) {
      return 'That start time has already passed — pick a later slot.';
    }
    if (_heads.text.trim().isNotEmpty &&
        int.tryParse(_heads.text.trim()) == null) {
      return 'Attendees needs to be a whole number.';
    }
    if (_headcount <= 0) return 'How many people are coming?';
    if (_overCapacity) {
      return '${facility.name} seats ${facility.capacity}. Lower the '
          'attendee count or pick a bigger space.';
    }
    if (_purpose.text.trim().isEmpty) {
      return 'The assigned administrator reads this — a sentence is enough.';
    }
    if (_attachments.isEmpty) {
      return 'Attach at least one supporting file.';
    }
    if (_quoteLoading) return 'Wait for the current price to finish loading.';
    if (_quoteError != null) return _quoteError;
    if (_serverQuote == null) {
      return 'A server price is required before submitting.';
    }
    if (_serverQuote?.terms.isNotEmpty == true && !_termsAccepted) {
      return 'Accept the reservation and payment terms before submitting.';
    }
    return null;
  }

  void _scheduleQuote() {
    _quoteTimer?.cancel();
    if (mounted) {
      setState(() {
        _serverQuote = null;
        _quoteError = null;
        _quoteLoading = true;
        _termsAccepted = false;
      });
    }
    _quoteTimer = Timer(const Duration(milliseconds: 250), _refreshQuote);
  }

  Future<void> _refreshQuote() async {
    if (_duration <= 0) {
      if (mounted) setState(() => _quoteLoading = false);
      return;
    }
    final request = ++_quoteRequest;
    if (mounted) {
      setState(() {
        _quoteLoading = true;
        _quoteError = null;
      });
    }
    final count = _weekly ? _occurrenceCount : 1;
    final startsAt = [for (var i = 0; i < count; i++) _at(_start, i)];
    final endsAt = [for (var i = 0; i < count; i++) _at(_end, i)];
    final results = await Future.wait<Object?>([
      widget.state.quoteReservation(
        facility: facility,
        startsAt: startsAt,
        endsAt: endsAt,
        headcount: _headcount,
        discountClaimId: _selectedVoucherId,
      ),
      widget.state.checkReservationOverlaps(startsAt: startsAt, endsAt: endsAt),
    ]);
    if (!mounted || request != _quoteRequest) return;
    final quote = results[0] as BackendReservationQuote?;
    final overlaps = results[1] as List<Map<String, dynamic>>;
    setState(() {
      _quoteLoading = false;
      _serverQuote = quote;
      _quoteError = quote == null
          ? widget.state.lastReservationError ??
                'The price could not be calculated.'
          : null;
      _termsAccepted = quote?.terms.isEmpty == true;
      _ownOverlaps = overlaps;
    });
  }

  Future<void> _chooseAttachments() async {
    if (_attachments.length >= 3) return;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.lengthInBytes > 10 * 1024 * 1024) {
      widget.state.showToast(
        const ToastMessage(
          'Supporting files must be 10 MB or smaller.',
          tone: AdvisoryTone.block,
        ),
      );
      return;
    }
    final mime = switch (file.name.split('.').last.toLowerCase()) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'pdf' => 'application/pdf',
      _ => '',
    };
    if (mime.isEmpty) {
      widget.state.showToast(
        const ToastMessage(
          'Attach a PDF, JPG, or PNG supporting file.',
          tone: AdvisoryTone.block,
        ),
      );
      return;
    }
    _attachments.add(
      ReservationUpload(name: file.name, mimeType: mime, bytes: bytes),
    );
    if (mounted) setState(() {});
  }

  void _toggleAmenity(String label) {
    setState(() {
      if (!_amenities.remove(label)) _amenities.add(label);
    });
  }

  void _removeAmenity(String label) {
    setState(() => _amenities.remove(label));
  }

  Future<void> _submit() async {
    setState(() => _attempted = true);
    if (_error != null) return;
    setState(() => _submitting = true);
    final count = _weekly ? _occurrenceCount : 1;
    final success = await widget.state.submitReservationRequest(
      facility: facility,
      startsAt: [for (var i = 0; i < count; i++) _at(_start, i)],
      endsAt: [for (var i = 0; i < count; i++) _at(_end, i)],
      heads: _headcount,
      purpose: _purpose.text.trim(),
      attachments: _attachments,
      requestedAmenities: normalizeRequestedAmenityLabels(facility, _amenities),
      quote: _serverQuote,
      acceptedTerms: _termsAccepted,
      discountClaimId: _selectedVoucherId,
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (success) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final mobile = widget.fullPage || screen.width < 600;
    final content = ColoredBox(
      color: context.srColors.surface,
      child: SrScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StudentFacilityGallery(
              facility: facility,
              selected: _selectedPhoto,
              mobile: mobile,
              showClose: !widget.fullPage,
              onSelected: (index) => setState(() => _selectedPhoto = index),
              onClose: () => Navigator.of(context).pop(),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                mobile ? 16 : 24,
                mobile ? 18 : 22,
                mobile ? 16 : 24,
                mobile ? 24 : 24,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 760;
                  final overview = StudentFacilityOverview(
                    facility: facility,
                    audience: widget.state.userAccount.pricingAudience,
                  );
                  final booking = _BookingForm(
                    account: widget.state.userAccount,
                    facility: facility,
                    quote: _serverQuote,
                    quoteLoading: _quoteLoading,
                    quoteError: _quoteError,
                    vouchers: _eligibleVouchers,
                    selectedVoucherId: _selectedVoucherId,
                    termsAccepted: _termsAccepted,
                    narrow: widget.fullPage ? false : mobile || !wide,
                    date: _date,
                    dates: _dates,
                    start: _start,
                    end: _end,
                    times: _times,
                    heads: _heads,
                    purpose: _purpose,
                    duration: _duration,
                    clashes: _clashes,
                    ownOverlaps: _ownOverlaps,
                    overCapacity: _overCapacity,
                    headcount: _headcount,
                    attempted: _attempted,
                    error: _error,
                    weekly: _weekly,
                    occurrenceCount: _occurrenceCount,
                    attachments: _attachments,
                    amenities: _amenities,
                    submitting: _submitting,
                    onDateChanged: (value) {
                      setState(() {
                        _date = value;
                        _clampTimes();
                      });
                      _scheduleQuote();
                    },
                    onStartChanged: (value) {
                      setState(() => _start = value);
                      _scheduleQuote();
                    },
                    onEndChanged: (value) {
                      setState(() => _end = value);
                      _scheduleQuote();
                    },
                    onFieldChanged: () => setState(() {}),
                    onWeeklyChanged: (value) {
                      setState(() => _weekly = value);
                      _scheduleQuote();
                    },
                    onOccurrenceCountChanged: (value) {
                      setState(() => _occurrenceCount = value);
                      _scheduleQuote();
                    },
                    onChooseAttachments: _chooseAttachments,
                    onRemoveAttachment: (index) =>
                        setState(() => _attachments.removeAt(index)),
                    onToggleAmenity: _toggleAmenity,
                    onRemoveAmenity: _removeAmenity,
                    onVoucherChanged: (value) {
                      setState(() {
                        _selectedVoucherId = value == 'none' ? null : value;
                        _termsAccepted = false;
                      });
                      _scheduleQuote();
                    },
                    onTermsAccepted: (value) =>
                        setState(() => _termsAccepted = value),
                    onSubmit: _submit,
                  );

                  if (!wide) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [overview, const SizedBox(height: 24), booking],
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 5, child: overview),
                      const SizedBox(width: 22),
                      SizedBox(width: 330, child: booking),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.fullPage) return content;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 960,
          maxHeight: screen.height - 40,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: content,
        ),
      ),
    );
  }

  List<LoyaltyDiscountClaim> get _eligibleVouchers => [
    for (final claim
        in widget.state.loyalty?.claims ?? const <LoyaltyDiscountClaim>[])
      if (claim.isUsable && claim.appliesTo(facility.id)) claim,
  ];
}

class _BookingForm extends StatelessWidget {
  const _BookingForm({
    required this.account,
    required this.facility,
    required this.quote,
    required this.quoteLoading,
    required this.quoteError,
    required this.vouchers,
    required this.selectedVoucherId,
    required this.termsAccepted,
    required this.narrow,
    required this.date,
    required this.dates,
    required this.start,
    required this.end,
    required this.times,
    required this.heads,
    required this.purpose,
    required this.duration,
    required this.clashes,
    required this.ownOverlaps,
    required this.overCapacity,
    required this.headcount,
    required this.attempted,
    required this.error,
    required this.weekly,
    required this.occurrenceCount,
    required this.attachments,
    required this.amenities,
    required this.submitting,
    required this.onDateChanged,
    required this.onStartChanged,
    required this.onEndChanged,
    required this.onFieldChanged,
    required this.onWeeklyChanged,
    required this.onOccurrenceCountChanged,
    required this.onChooseAttachments,
    required this.onRemoveAttachment,
    required this.onToggleAmenity,
    required this.onRemoveAmenity,
    required this.onVoucherChanged,
    required this.onTermsAccepted,
    required this.onSubmit,
  });

  final Account account;
  final Facility facility;
  final BackendReservationQuote? quote;
  final bool quoteLoading;
  final String? quoteError;
  final List<LoyaltyDiscountClaim> vouchers;
  final String? selectedVoucherId;
  final bool termsAccepted;
  final bool narrow;
  final String date;
  final List<String> dates;
  final String start;
  final String end;
  final List<String> times;
  final TextEditingController heads;
  final TextEditingController purpose;
  final double duration;
  final List<Booking> clashes;
  final List<Map<String, dynamic>> ownOverlaps;
  final bool overCapacity;
  final int headcount;
  final bool attempted;
  final String? error;
  final bool weekly;
  final int occurrenceCount;
  final List<ReservationUpload> attachments;
  final Set<String> amenities;
  final bool submitting;
  final ValueChanged<String> onDateChanged;
  final ValueChanged<String> onStartChanged;
  final ValueChanged<String> onEndChanged;
  final VoidCallback onFieldChanged;
  final ValueChanged<bool> onWeeklyChanged;
  final ValueChanged<int> onOccurrenceCountChanged;
  final VoidCallback onChooseAttachments;
  final ValueChanged<int> onRemoveAttachment;
  final ValueChanged<String> onToggleAmenity;
  final ValueChanged<String> onRemoveAmenity;
  final ValueChanged<String?> onVoucherChanged;
  final ValueChanged<bool> onTermsAccepted;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: context.srColors.surfaceSubtle,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.srColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Request this facility', style: sans(16, w: 600, tracking: -.015)),
        const SizedBox(height: 4),
        Text(
          'Choose a schedule and tell the assigned administrator what you need it for.',
          style: sans(11.5, height: 1.5, color: context.srColors.ink4),
        ),
        const SizedBox(height: 16),
        _row(
          narrow: narrow,
          left: _field(
            'Date',
            SrSelect<String>(
              value: date,
              items: dates,
              semanticLabel: 'Date',
              fontSize: 12.5,
              labelOf: (value) => value,
              onChanged: (value) {
                if (value != null) onDateChanged(value);
              },
            ),
          ),
          right: _field(
            'Attendees',
            SrTextField(
              controller: heads,
              placeholder: '0',
              semanticLabel: 'Attendees',
              mono: true,
              fontSize: 12.5,
              keyboardType: TextInputType.number,
              // Digits only: `TextInputType.number` is a hint the desktop and
              // web keyboards ignore, so letters and signs get through.
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(5),
              ],
              hasError: attempted && (headcount <= 0 || overCapacity),
              onChanged: (_) => onFieldChanged(),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _row(
          narrow: narrow,
          left: _field(
            'From',
            SrSelect<String>(
              value: start,
              items: times,
              semanticLabel: 'Start time',
              fontSize: 12.5,
              labelOf: (value) => value,
              onChanged: (value) {
                if (value != null) onStartChanged(value);
              },
            ),
          ),
          right: _field(
            'To',
            SrSelect<String>(
              value: end,
              items: times,
              semanticLabel: 'End time',
              fontSize: 12.5,
              labelOf: (value) => value,
              onChanged: (value) {
                if (value != null) onEndChanged(value);
              },
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          duration <= 0
              ? 'Pick an end time after the start.'
              : '${duration.toStringAsFixed(duration % 1 == 0 ? 0 : 1)} '
                    'hours · maximum ${facility.maxDuration}',
          style: sans(11, color: context.srColors.muted),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          decoration: BoxDecoration(
            color: context.srColors.surface,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: context.srColors.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Repeat weekly', style: sans(11.5, w: 500)),
                  ),
                  SrToggle(
                    value: weekly,
                    label: 'Repeat weekly',
                    onChanged: onWeeklyChanged,
                  ),
                ],
              ),
              if (weekly) ...[
                const SizedBox(height: 9),
                SrSelect<int>(
                  value: occurrenceCount,
                  items: const [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
                  semanticLabel: 'Number of weekly occurrences',
                  labelOf: (value) => '$value occurrences',
                  onChanged: (value) {
                    if (value != null) onOccurrenceCountChanged(value);
                  },
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        const SrLabel('What is it for?'),
        SrTextField(
          controller: purpose,
          placeholder:
              'The assigned administrator reads this — a sentence is enough.',
          semanticLabel: 'Purpose',
          fontSize: 12.5,
          minLines: 3,
          maxLines: 5,
          keyboardType: TextInputType.multiline,
          hasError: attempted && purpose.text.trim().isEmpty,
          onChanged: (_) => onFieldChanged(),
        ),
        const SizedBox(height: 12),
        AmenityRequestField(
          includedAmenities: includedFacilityAmenities(facility),
          requestableAmenities: requestableAmenityLabels(facility),
          selectedRequestedAmenities: amenities,
          onToggle: onToggleAmenity,
          onRemove: onRemoveAmenity,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                'Supporting files',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sans(
                  11.5,
                  w: 500,
                  color: attempted && attachments.isEmpty
                      ? context.srColors.error
                      : context.srColors.ink2,
                ),
              ),
            ),
            SrButton(
              label: attachments.isEmpty ? 'Attach files' : 'Add another',
              dense: true,
              fontSize: 11,
              onPressed: attachments.length < 3 ? onChooseAttachments : null,
            ),
          ],
        ),
        if (attempted && attachments.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              'At least one supporting file is required.',
              style: sans(11, color: context.srColors.error),
            ),
          ),
        if (attachments.isNotEmpty)
          for (var index = 0; index < attachments.length; index++)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.attach_file_rounded,
                    size: 15,
                    color: context.srColors.muted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      attachments[index].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(11, color: context.srColors.ink3),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove ${attachments[index].name}',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onRemoveAttachment(index),
                    icon: const Icon(Icons.close_rounded, size: 16),
                  ),
                ],
              ),
            ),
        if (clashes.isNotEmpty) ...[
          const SizedBox(height: 10),
          _Alert(
            background: context.srColors.amberTint,
            border: context.srColors.amberLine,
            foreground: context.srColors.amberTitle,
            text:
                'Someone already has this room from '
                '${clashes.first.start} to ${clashes.first.end}. You can still '
                'ask — the assigned administrator decides, and will offer the next free '
                'slot if it cannot be moved.',
          ),
        ],
        if (ownOverlaps.isNotEmpty) ...[
          const SizedBox(height: 10),
          _Alert(
            background: context.srColors.amberTint,
            border: context.srColors.amberLine,
            foreground: context.srColors.amberTitle,
            text:
                'This overlaps with another active reservation of yours'
                '${ownOverlaps.first['facility_name'] == null ? '' : ' at ${ownOverlaps.first['facility_name']}'}. '
                'You can still send this request.',
          ),
        ],
        if (overCapacity) ...[
          const SizedBox(height: 8),
          _Alert(
            background: context.srColors.redTint,
            border: context.srColors.redLine,
            foreground: context.srColors.redInk,
            text:
                '$headcount people in a ${facility.capacity}-seat room. '
                'Lower the attendee count or pick a bigger space — this '
                'cannot be sent as it stands.',
          ),
        ],
        if (vouchers.isNotEmpty) ...[
          const SizedBox(height: 12),
          _field(
            'Loyalty voucher',
            SrSelect<String>(
              value: selectedVoucherId ?? 'none',
              items: ['none', for (final voucher in vouchers) voucher.id],
              semanticLabel: 'Loyalty voucher',
              labelOf: (value) {
                if (value == 'none') return 'No loyalty discount';
                final voucher = vouchers.firstWhere((item) => item.id == value);
                return '${voucher.valueLabel} · ${voucher.offerName}';
              },
              onChanged: onVoucherChanged,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          decoration: BoxDecoration(
            color: context.srColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: context.srColors.hairline),
          ),
          child: quoteLoading
              ? const LinearProgressIndicator(minHeight: 2)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (quote != null && quote!.discountAmountCentavos > 0) ...[
                      _MoneyRow(
                        label: 'Subtotal',
                        value:
                            quote!.facilityAmountCentavos +
                            quote!.amenityAmountCentavos,
                      ),
                      const SizedBox(height: 4),
                      _MoneyRow(
                        label: 'Loyalty discount',
                        value: -quote!.discountAmountCentavos,
                        tone: context.srColors.success,
                      ),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Expanded(
                          child: Text(
                            'Authoritative total',
                            style: sans(
                              11.5,
                              w: 500,
                              color: context.srColors.ink2,
                            ),
                          ),
                        ),
                        Text(
                          quote == null
                              ? '—'
                              : pesoFromCentavos(quote!.totalAmountCentavos),
                          style: sans(15, w: 600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      quoteError ??
                          (quote?.totalAmountCentavos == 0
                              ? 'No payment is required under this facility’s ${account.pricingAudience} rate. Approval confirms the reservation.'
                              : '${pesoFromCentavos(quote?.requiredDownPaymentCentavos ?? 0)} is required after approval. The slot is held while GCash proof is submitted and reviewed.'),
                      style: sans(
                        10.5,
                        height: 1.6,
                        color: context.srColors.muted,
                      ),
                    ),
                  ],
                ),
        ),
        if (quote?.terms.isNotEmpty == true) ...[
          const SizedBox(height: 10),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: Text('Review terms', style: sans(11.5, w: 600)),
            children: [
              for (final term in quote!.terms)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${term.title} · version ${term.version}\n${term.content}',
                      style: sans(
                        10.5,
                        height: 1.5,
                        color: context.srColors.ink4,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          CheckboxListTile(
            value: termsAccepted,
            onChanged: (value) => onTermsAccepted(value ?? false),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              'I accept ${quote!.terms.map((term) => term.title).join(' and ')}.',
              style: sans(11.5, height: 1.4, color: context.srColors.ink2),
            ),
            subtitle: Text(
              'Acceptance and the exact policy versions are recorded with this reservation.',
              style: sans(10.5, height: 1.4, color: context.srColors.muted),
            ),
          ),
        ],
        SrErrorText(error),
        const SizedBox(height: 12),
        SrButton(
          label: submitting ? 'Sending…' : 'Send request to the registrar',
          kind: SrButtonKind.primary,
          expand: true,
          minHeight: 46,
          fontSize: 13,
          onPressed: submitting ? null : () => onSubmit(),
        ),
      ],
    ),
  );

  Widget _field(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [SrLabel(label), child],
  );

  Widget _row({
    required bool narrow,
    required Widget left,
    required Widget right,
  }) => narrow
      ? Column(children: [left, const SizedBox(height: 10), right])
      : Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 10),
            Expanded(child: right),
          ],
        );
}

class _MoneyRow extends StatelessWidget {
  const _MoneyRow({required this.label, required this.value, this.tone});

  final String label;
  final int value;
  final Color? tone;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          label,
          style: sans(10.5, color: context.srColors.textMuted),
        ),
      ),
      Text(
        '${value < 0 ? '-' : ''}${pesoFromCentavos(value.abs())}',
        style: mono(11, w: 600, color: tone ?? context.srColors.text),
      ),
    ],
  );
}

class _Alert extends StatelessWidget {
  const _Alert({
    required this.background,
    required this.border,
    required this.foreground,
    required this.text,
  });

  final Color background;
  final Color border;
  final Color foreground;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: border),
    ),
    child: Text(text, style: sans(11.5, height: 1.55, color: foreground)),
  );
}
