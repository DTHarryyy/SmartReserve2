import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../backend/supabase_service.dart';
import '../../model/account.dart';
import '../../model/facility.dart';
import '../../model/facility_photo.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../util/geo.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/sr_controls.dart';

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
    backgroundColor: SR.surface,
    appBar: AppBar(
      backgroundColor: SR.surface,
      foregroundColor: SR.ink,
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
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: SR.border),
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
  int _selectedPhoto = 0;

  Facility get facility => widget.facility;

  @override
  void initState() {
    super.initState();
    _dateValues = _availableDates();
    _dates = [for (final value in _dateValues) _dateLabel(value)];
    _date = _dates.first;
    _start = _times.first;
    _end = _times.length > 2 ? _times[2] : _times.last;
  }

  @override
  void dispose() {
    _heads.dispose();
    _purpose.dispose();
    super.dispose();
  }

  List<String> get _times => [
    for (
      var minutes = facility.openHour * 60;
      minutes <= facility.closeHour * 60;
      minutes += 30
    )
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
          '${(minutes % 60).toString().padLeft(2, '0')}',
  ];

  List<DateTime> _availableDates() {
    final today = campusNow();
    final start = DateTime(today.year, today.month, today.day);
    final values = <DateTime>[];
    for (var offset = 0; offset <= facility.advanceBookingDays; offset++) {
      final date = start.add(Duration(days: offset));
      if (_facilityOpenOn(date)) values.add(date);
    }
    return values.isEmpty ? [start] : values;
  }

  bool _facilityOpenOn(DateTime date) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final day = names[date.weekday - 1];
    if (facility.days == 'Mon–Sun') return true;
    if (facility.days == 'Mon–Sat') return date.weekday <= DateTime.saturday;
    if (facility.days == 'Mon–Fri') return date.weekday <= DateTime.friday;
    return facility.days.split(',').map((part) => part.trim()).contains(day);
  }

  static String _dateLabel(DateTime date) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
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
    if (widget.state.studentAccount.status == AccountStatus.suspended) {
      return widget.state.studentAccount.suspendReason ??
          'This account is suspended and cannot submit new requests.';
    }
    if (_duration <= 0) return 'The end time has to be after the start time.';
    if (_headcount <= 0) return 'How many people are coming?';
    if (_purpose.text.trim().isEmpty) {
      return 'The registrar reads this — a sentence is enough.';
    }
    return null;
  }

  Future<void> _chooseAttachments() async {
    if (_attachments.length >= 3) return;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.lengthInBytes > 10 * 1024 * 1024) return;
    final extension = file.extension?.toLowerCase();
    final mime = switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'pdf' => 'application/pdf',
      _ => '',
    };
    if (mime.isNotEmpty) {
      _attachments.add(
        ReservationUpload(name: file.name, mimeType: mime, bytes: bytes),
      );
    }
    if (mounted) setState(() {});
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
      color: SR.surface,
      child: Scrollbar(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FacilityGallery(
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
                    final overview = _FacilityOverview(facility: facility);
                    final booking = _BookingForm(
                      account: widget.state.studentAccount,
                      facility: facility,
                      free: widget.state.studentAccount.reservesFree,
                      quote: widget.state.quoteFor(
                        facility,
                        _duration <= 0 ? 0 : _duration,
                      ),
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
                      overCapacity: _overCapacity,
                      headcount: _headcount,
                      attempted: _attempted,
                      error: _error,
                      weekly: _weekly,
                      occurrenceCount: _occurrenceCount,
                      attachments: _attachments,
                      submitting: _submitting,
                      onDateChanged: (value) => setState(() => _date = value),
                      onStartChanged: (value) => setState(() => _start = value),
                      onEndChanged: (value) => setState(() => _end = value),
                      onFieldChanged: () => setState(() {}),
                      onWeeklyChanged: (value) =>
                          setState(() => _weekly = value),
                      onOccurrenceCountChanged: (value) =>
                          setState(() => _occurrenceCount = value),
                      onChooseAttachments: _chooseAttachments,
                      onRemoveAttachment: (index) =>
                          setState(() => _attachments.removeAt(index)),
                      onSubmit: _submit,
                    );

                    if (!wide) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          overview,
                          const SizedBox(height: 24),
                          booking,
                        ],
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
}

class _FacilityGallery extends StatelessWidget {
  const _FacilityGallery({
    required this.facility,
    required this.selected,
    required this.mobile,
    required this.showClose,
    required this.onSelected,
    required this.onClose,
  });

  final Facility facility;
  final int selected;
  final bool mobile;
  final bool showClose;
  final ValueChanged<int> onSelected;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final photos = facility.photos;
    final safeSelected = photos.isEmpty
        ? 0
        : selected.clamp(0, photos.length - 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: mobile ? 218 : 300,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedSwitcher(
                duration: SR.stateChange,
                child: photos.isEmpty
                    ? const PlaceholderStripes(
                        key: ValueKey('empty-gallery'),
                        hue: 215,
                        caption: 'No facility photos available',
                        captionSize: 11,
                      )
                    : FacilityPhotoImage(
                        key: ValueKey(photos[safeSelected].id),
                        photo: photos[safeSelected],
                      ),
              ),
              Positioned(
                left: 14,
                bottom: 14,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xD910141A),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    photos.isEmpty
                        ? 'NO PHOTOS'
                        : '${safeSelected + 1} / ${photos.length} PHOTOS',
                    style: mono(9.5, w: 500, color: Colors.white),
                  ),
                ),
              ),
              if (showClose)
                Positioned(
                  right: 12,
                  top: 12,
                  child: SrIconButton(
                    glyph: '✕',
                    tooltip: 'Close',
                    size: 34,
                    border: null,
                    background: const Color(0xF0FFFFFF),
                    onPressed: onClose,
                  ),
                ),
            ],
          ),
        ),
        if (photos.length > 1)
          Container(
            height: 76,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: const BoxDecoration(
              color: SR.surfaceSubtle,
              border: Border(bottom: BorderSide(color: SR.hairline)),
            ),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => _PhotoThumbnail(
                photo: photos[index],
                index: index,
                selected: index == safeSelected,
                onTap: () => onSelected(index),
              ),
            ),
          ),
      ],
    );
  }
}

class _PhotoThumbnail extends StatelessWidget {
  const _PhotoThumbnail({
    required this.photo,
    required this.index,
    required this.selected,
    required this.onTap,
  });

  final FacilityPhoto photo;
  final int index;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    key: ValueKey('facility-photo-thumbnail-$index'),
    button: true,
    selected: selected,
    label: 'Show facility photo ${index + 1}',
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: SR.stateChange,
        width: 72,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: SR.surface,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? SR.blue : SR.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: FacilityPhotoImage(photo: photo, captionSize: 8),
        ),
      ),
    ),
  );
}

class _FacilityOverview extends StatelessWidget {
  const _FacilityOverview({required this.facility});

  final Facility facility;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          SrPill(
            label: facility.state.label,
            background: facility.state.background,
            foreground: facility.state.foreground,
          ),
          SrPill(
            label: facility.category,
            background: SR.blueTint,
            foreground: SR.blueDark,
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        facility.name,
        style: sans(23, w: 600, tracking: -.025, height: 1.15),
      ),
      const SizedBox(height: 5),
      Text(facility.whereLine, style: sans(12.5, color: SR.ink4)),
      const SizedBox(height: 13),
      Text(
        facility.description.isEmpty
            ? 'No description has been added for this facility.'
            : facility.description,
        style: sans(13, height: 1.65, color: SR.ink3),
      ),
      const SizedBox(height: 22),
      const _SectionTitle('Facility details'),
      const SizedBox(height: 9),
      _DetailGrid(
        items: [
          _DetailItem('CAPACITY', '${facility.capacity} seats'),
          _DetailItem('OPEN HOURS', facility.hours),
          _DetailItem('OPEN DAYS', facility.days),
          _DetailItem(
            'APPROVAL',
            facility.approvalRequired ? 'Required' : 'Instant booking',
          ),
          _DetailItem('MAX DURATION', facility.maxDuration),
          _DetailItem('BOOK AHEAD', facility.advance),
          _DetailItem('BOOKING BUFFER', facility.buffer),
          _DetailItem(
            'LISTING',
            facility.publicListing ? 'Publicly listed' : 'Not public',
          ),
        ],
      ),
      const SizedBox(height: 22),
      const _SectionTitle('Location'),
      const SizedBox(height: 9),
      _LocationDetails(facility: facility),
      const SizedBox(height: 22),
      const _SectionTitle('Amenities'),
      const SizedBox(height: 9),
      if (facility.amenities.isEmpty)
        Text('No amenities recorded.', style: sans(12, color: SR.muted))
      else
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (final amenity in facility.amenities)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: SR.dividerSoft,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: SR.hairline),
                ),
                child: Text(amenity, style: sans(11.5, color: SR.ink3)),
              ),
          ],
        ),
      const SizedBox(height: 20),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: SR.surfaceSubtle,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: SR.hairline),
        ),
        child: Wrap(
          spacing: 18,
          runSpacing: 5,
          children: [
            Text(
              '${facility.photos.length} ${facility.photos.length == 1 ? 'photo' : 'photos'}',
              style: mono(10.5, color: SR.ink4),
            ),
            Text(
              '${facility.bookings} bookings on record',
              style: mono(10.5, color: SR.ink4),
            ),
            Text(
              'Updated ${facility.updated}',
              style: mono(10.5, color: SR.ink4),
            ),
          ],
        ),
      ),
    ],
  );
}

class _DetailItem {
  const _DetailItem(this.label, this.value);

  final String label;
  final String value;
}

class _DetailGrid extends StatelessWidget {
  const _DetailGrid({required this.items});

  final List<_DetailItem> items;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 520 ? 3 : 2;
      const gap = 8.0;
      final width = (constraints.maxWidth - (gap * (columns - 1))) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final item in items)
            SizedBox(
              width: width,
              child: Container(
                constraints: const BoxConstraints(minHeight: 68),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: SR.surfaceSubtle,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: SR.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.label, style: keyLabel),
                    const SizedBox(height: 5),
                    Text(
                      item.value.isEmpty ? 'Not specified' : item.value,
                      style: sans(11.5, w: 500, color: SR.ink2, height: 1.35),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _LocationDetails extends StatelessWidget {
  const _LocationDetails({required this.facility});

  final Facility facility;

  Future<void> _openMap() async {
    final point = facility.coords;
    if (point == null) return;
    final uri = Uri.https('www.google.com', '/maps/search/', {
      'api': '1',
      'query': '${point.latitude},${point.longitude}',
    });
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String get _address {
    final parts = <String>[
      if (facility.street.trim().isNotEmpty) facility.street.trim(),
      if (facility.barangay.trim().isNotEmpty) facility.barangay.trim(),
      if (facility.municipality.trim().isNotEmpty) facility.municipality.trim(),
      if (facility.province.trim().isNotEmpty) facility.province.trim(),
      if (facility.region.trim().isNotEmpty) facility.region.trim(),
      if (facility.country.trim().isNotEmpty) facility.country.trim(),
    ];
    return parts.isEmpty ? 'No street address recorded' : parts.join(', ');
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: SR.blueTint2,
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: SR.blueLine),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(facility.campusName, style: sans(12.5, w: 600, color: SR.ink2)),
        const SizedBox(height: 3),
        Text(facility.whereLine, style: sans(11.5, color: SR.ink4)),
        const SizedBox(height: 3),
        Text(_address, style: sans(11.5, height: 1.5, color: SR.ink4)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SrPill(
              label: facility.pinConfidence.label,
              background: facility.pinConfidence == PinConfidence.verified
                  ? SR.greenTint
                  : facility.pinConfidence == PinConfidence.needsCheck
                  ? SR.amberTint
                  : SR.dividerSoft,
              foreground: facility.pinConfidence.color,
              monospace: true,
              fontSize: 9,
            ),
            if (facility.coords != null)
              Text(
                formatCoords(facility.coords!),
                style: mono(9.5, color: SR.muted),
              ),
            if (facility.accuracy != null)
              Text(
                '±${facility.accuracy} m accuracy',
                style: mono(9.5, color: SR.muted),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SrButton(
          label: facility.coords == null ? 'Map unavailable' : 'Open map ↗',
          kind: SrButtonKind.primary,
          expand: true,
          minHeight: 42,
          onPressed: facility.coords == null ? null : _openMap,
        ),
      ],
    ),
  );
}

class _BookingForm extends StatelessWidget {
  const _BookingForm({
    required this.account,
    required this.facility,
    required this.free,
    required this.quote,
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
    required this.overCapacity,
    required this.headcount,
    required this.attempted,
    required this.error,
    required this.weekly,
    required this.occurrenceCount,
    required this.attachments,
    required this.submitting,
    required this.onDateChanged,
    required this.onStartChanged,
    required this.onEndChanged,
    required this.onFieldChanged,
    required this.onWeeklyChanged,
    required this.onOccurrenceCountChanged,
    required this.onChooseAttachments,
    required this.onRemoveAttachment,
    required this.onSubmit,
  });

  final Account account;
  final Facility facility;
  final bool free;
  final int quote;
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
  final bool overCapacity;
  final int headcount;
  final bool attempted;
  final String? error;
  final bool weekly;
  final int occurrenceCount;
  final List<ReservationUpload> attachments;
  final bool submitting;
  final ValueChanged<String> onDateChanged;
  final ValueChanged<String> onStartChanged;
  final ValueChanged<String> onEndChanged;
  final VoidCallback onFieldChanged;
  final ValueChanged<bool> onWeeklyChanged;
  final ValueChanged<int> onOccurrenceCountChanged;
  final VoidCallback onChooseAttachments;
  final ValueChanged<int> onRemoveAttachment;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: SR.surfaceSubtle,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SR.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Request this facility', style: sans(16, w: 600, tracking: -.015)),
        const SizedBox(height: 4),
        Text(
          'Choose a schedule and tell the registrar what you need it for.',
          style: sans(11.5, height: 1.5, color: SR.ink4),
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
              hasError: attempted && headcount <= 0,
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
          style: sans(11, color: SR.muted),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          decoration: BoxDecoration(
            color: SR.surface,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: SR.hairline),
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
          placeholder: 'The registrar reads this — a sentence is enough.',
          semanticLabel: 'Purpose',
          fontSize: 12.5,
          minLines: 3,
          maxLines: 5,
          keyboardType: TextInputType.multiline,
          hasError: attempted && purpose.text.trim().isEmpty,
          onChanged: (_) => onFieldChanged(),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                'Supporting files · optional',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sans(11.5, w: 500, color: SR.ink2),
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
        if (attachments.isNotEmpty)
          for (var index = 0; index < attachments.length; index++)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const Icon(Icons.attach_file_rounded, size: 15, color: SR.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      attachments[index].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(11, color: SR.ink3),
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
            background: SR.amberTint,
            border: SR.amberLine,
            foreground: SR.amberTitle,
            text:
                'Someone already has this room from '
                '${clashes.first.start} to ${clashes.first.end}. You can still '
                'ask — the registrar decides, and will offer the next free '
                'slot if it cannot be moved.',
          ),
        ],
        if (overCapacity) ...[
          const SizedBox(height: 8),
          _Alert(
            background: SR.redTint,
            border: SR.redLine,
            foreground: const Color(0xFF912018),
            text:
                '$headcount people in a ${facility.capacity}-seat room. '
                'Requests over capacity are almost always declined — pick a '
                'bigger space.',
          ),
        ],
        const SizedBox(height: 12),
        if (free)
          _Alert(
            background: const Color(0xFFF2FDF7),
            border: const Color(0xFFB7E9CD),
            foreground: const Color(0xFF0A5C3A),
            text: account.verification == VerificationState.pending
                ? 'No payment — you can send this request while your '
                      'verification is in progress. It is released for review '
                      'once verification is approved.'
                : 'No payment — verified campus members reserve free, subject '
                      'to approval.',
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            decoration: BoxDecoration(
              color: SR.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: SR.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(
                        'Estimated charge',
                        style: sans(11.5, w: 500, color: SR.ink2),
                      ),
                    ),
                    Text('₱$quote', style: sans(15, w: 600)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Payment status is tracked only; no real charge is made. '
                  'Approval marks it authorised and check-in marks it captured.',
                  style: sans(10.5, height: 1.6, color: SR.muted),
                ),
              ],
            ),
          ),
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Text(label, style: sans(13, w: 600, color: SR.ink2));
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
