import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../app/app_view.dart';
import '../../model/account.dart';
import '../../model/facility.dart';
import '../../model/facility_photo.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../util/campus_calendar.dart';
import '../../widgets/decision_widgets.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_controls.dart';
import '../assistant/assistant_chat_page.dart';
import '../assistant/assistant_controller.dart';
import 'booking_sheet.dart';

enum StudentTab {
  browse('Browse', 'Browse', Icons.grid_view_rounded),
  mine('My reservations', 'Mine', Icons.event_note_rounded),
  account('Account', 'Account', Icons.person_rounded);

  const StudentTab(this.label, this.short, this.icon);

  final String label;

  final String short;
  final IconData icon;
}

class StudentApp extends StatefulWidget {
  const StudentApp({super.key});

  @override
  State<StudentApp> createState() => _StudentAppState();
}

class _StudentAppState extends State<StudentApp> {
  StudentTab _tab = StudentTab.browse;

  String? _editingField;
  final _editController = TextEditingController();
  final _browseSearch = TextEditingController();
  String _browseQuery = '';
  String _browseCategory = 'All categories';
  int _minimumCapacity = 0;
  final Set<String> _browseAmenities = {};
  String? _bannerDismissalKey;
  bool? _bannerDismissed;
  late final AssistantController _assistant;

  static const _capacityFilters = <String, int>{
    'Any capacity': 0,
    '25+ seats': 25,
    '50+ seats': 50,
    '100+ seats': 100,
    '500+ seats': 500,
  };

  @override
  void initState() {
    super.initState();
    _assistant = AssistantController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncBannerDismissal(AppScope.of(context).userAccount);
  }

  @override
  void dispose() {
    _editController.dispose();
    _browseSearch.dispose();
    _assistant.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final account = state.userAccount;
    final width = MediaQuery.sizeOf(context).width;
    final narrow = SR.isCompact(width);

    return ColoredBox(
      color: SR.bg,
      child: Column(
        children: [
          _header(state, account, narrow),
          Expanded(
            child: switch (_tab) {
              StudentTab.browse => _scrollable(_browse(state, account), width, narrow),
              StudentTab.mine => _scrollable(_mine(state), width, narrow),
              StudentTab.account => _scrollable(_account(state, account), width, narrow),
            },
          ),
          _BottomNav(
            selected: _tab,
            onSelect: (tab) => setState(() => _tab = tab),
            onOpenAssistant: () => _openAssistant(context),
          ),
        ],
      ),
    );
  }

  /// Opens the assistant as its own pushed screen, rather than as a tab
  /// within this shell — it needs a bare "back + name" app bar and no
  /// bottom nav, which only a dedicated route (not a tab body) can give it.
  Future<void> _openAssistant(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => AssistantChatPage(controller: _assistant)),
  );

  /// Wraps a tab's body in the shared page scroll shell. Kept out of the
  /// Assistant tab, which needs its own bounded, auto-scrolling thread and
  /// a bottom-pinned composer instead — see `assistant_tab.dart`.
  Widget _scrollable(Widget child, double width, bool narrow) => Scrollbar(
    child: SingleChildScrollView(
      padding: SR.pageInsets(width, top: narrow ? 14 : 20),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: child,
        ),
      ),
    ),
  );

  Widget _header(AppState state, Account account, bool narrow) => Container(
    padding: EdgeInsets.symmetric(horizontal: narrow ? 14 : 20, vertical: 12),
    decoration: const BoxDecoration(
      color: SR.bg,
      border: Border(bottom: BorderSide(color: SR.border)),
    ),
    child: Row(
      children: [
        Initials(text: account.initials, size: 34, fontSize: 11),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                account.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sans(13, w: 600, tracking: -.01),
              ),
              Text(
                account.email,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono(10, color: SR.muted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              tooltip: 'Notifications',
              onPressed: () => _showNotifications(state),
              icon: const Icon(Icons.notifications_none_rounded, size: 20),
            ),
            if (state.unreadNotifications > 0)
              Positioned(
                right: 2,
                top: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: SR.red,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${state.unreadNotifications}',
                    style: mono(8.5, w: 600, color: SR.surface),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(width: 4),
        SrPill(
          label: switch (account.verification) {
            VerificationState.verified => 'VERIFIED',
            VerificationState.pending =>
              narrow ? 'IN PROCESS' : 'VERIFICATION IN PROCESS',
            VerificationState.rejected => 'NOT VERIFIED',
            VerificationState.none => 'GUEST',
          },
          background: account.verification.background,
          foreground: account.verification.foreground,
          monospace: true,
          fontSize: 9.5,
        ),
      ],
    ),
  );

  Future<void> _showNotifications(AppState state) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text('Notifications', style: sans(16, w: 600)),
              ),
              const Divider(height: 1),
              Expanded(
                child: state.notifications.isEmpty
                    ? Center(
                        child: Text(
                          'No notifications yet.',
                          style: sans(12, color: SR.muted),
                        ),
                      )
                    : ListView.separated(
                        itemCount: state.notifications.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = state.notifications[index];
                          return ListTile(
                            tileColor: item.unread ? SR.blueTint : null,
                            title: Text(
                              item.title,
                              style: sans(12.5, w: item.unread ? 600 : 500),
                            ),
                            subtitle: Text(
                              item.body,
                              style: sans(11, height: 1.45, color: SR.ink4),
                            ),
                            onTap: () async {
                              Navigator.pop(context);
                              await state.openNotification(item);
                              if (mounted) {
                                setState(() => _tab = StudentTab.mine);
                              }
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _browse(AppState state, Account account) {
    final bookable = state.bookableFacilities;
    final categories = {
      for (final facility in bookable) facility.category,
    }.toList()..sort();
    final amenities = {
      for (final facility in bookable) ...facility.amenities,
    }.toList()..sort();
    final visible = state.searchFacilities(
      query: _browseQuery,
      category: _browseCategory,
      minCapacity: _minimumCapacity,
      amenities: _browseAmenities,
    );
    final filtersActive =
        _browseQuery.trim().isNotEmpty ||
        _browseCategory != 'All categories' ||
        _minimumCapacity > 0 ||
        _browseAmenities.isNotEmpty;
    final narrow = SR.isCompact(MediaQuery.sizeOf(context).width);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_shouldShowBanner(account))
          _Banner(
            background: account.verification == VerificationState.pending
                ? SR.amberTint
                : SR.greenTint,
            border: account.verification == VerificationState.pending
                ? SR.amberLine
                : const Color(0xFFB7E9CD),
            foreground: account.verification == VerificationState.pending
                ? SR.amberTitle
                : SR.greenDark,
            title: account.verification == VerificationState.pending
                ? 'Verification in process'
                : 'You are verified',
            body: account.verification == VerificationState.pending
                ? 'You can browse facilities and send reservation requests now. '
                      'Your request is held until verification is approved.'
                : 'Your campus membership is confirmed. Browse facilities and '
                      'send reservation requests whenever you are ready.',
            onDismiss: _dismissBanner,
          ),
        const SizedBox(height: 4),
        _browseFilters(
          narrow: narrow,
          categories: categories,
          amenities: amenities,
          filtersActive: filtersActive,
        ),
        if (visible.isEmpty)
          _BrowseEmpty(onClear: _clearBrowseFilters)
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = ((constraints.maxWidth + 12) / 272).floor().clamp(
                1,
                3,
              );
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                itemCount: visible.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  mainAxisExtent: 232,
                ),
                itemBuilder: (context, index) => _FacilityCard(
                  facility: visible[index],
                  free: account.reservesFree,
                  quote: state.quoteFor(visible[index], 2),
                  onTap: () => showBookingSheet(
                    context,
                    state: state,
                    facility: visible[index],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _browseFilters({
    required bool narrow,
    required List<String> categories,
    required List<String> amenities,
    required bool filtersActive,
  }) {
    final search = FilterSearch(
      controller: _browseSearch,
      placeholder: 'Search facilities',
      width: narrow ? double.infinity : 260,
      onChanged: (value) => setState(() => _browseQuery = value),
    );
    final category = FilterSelect(
      value: categories.contains(_browseCategory)
          ? _browseCategory
          : 'All categories',
      items: ['All categories', ...categories],
      semanticLabel: 'Filter by category',
      onChanged: (value) => setState(() => _browseCategory = value),
    );
    final capacity = FilterSelect(
      value: _capacityFilters.entries
          .firstWhere((entry) => entry.value == _minimumCapacity)
          .key,
      items: _capacityFilters.keys.toList(),
      semanticLabel: 'Filter by minimum capacity',
      onChanged: (value) =>
          setState(() => _minimumCapacity = _capacityFilters[value]!),
    );
    final amenity = _AmenitiesFilter(
      amenities: amenities,
      selected: _browseAmenities,
      onToggle: (value) => setState(() {
        if (!_browseAmenities.remove(value)) _browseAmenities.add(value);
      }),
    );
    final clear = SrButton(
      label: 'Clear filters',
      dense: true,
      fontSize: 11,
      onPressed: _clearBrowseFilters,
    );

    if (narrow) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A fixed height, not IntrinsicHeight: both FilterSearch and
            // CompactFilterButton build a LayoutBuilder, which cannot report
            // intrinsic dimensions and throws during layout.
            SizedBox(
              height: 44,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: search),
                  const SizedBox(width: 8),
                  CompactFilterButton(
                    minHeight: 0,
                    activeCount:
                        (_browseCategory == 'All categories' ? 0 : 1) +
                        (_minimumCapacity == 0 ? 0 : 1) +
                        (_browseAmenities.isEmpty ? 0 : 1),
                    onPressed: () => _showBrowseFilters(categories, amenities),
                  ),
                ],
              ),
            ),
            if (filtersActive) ...[
              const SizedBox(height: 8),
              Row(children: [const Spacer(), clear]),
            ],
          ],
        ),
      );
    }

    return FilterBar(
      children: [
        search,
        SizedBox(width: 200, child: category),
        SizedBox(width: 200, child: capacity),
        SizedBox(width: 200, child: amenity),
        if (filtersActive) clear,
      ],
    );
  }

  Future<void> _showBrowseFilters(
    List<String> categories,
    List<String> amenities,
  ) => showSrFilterSheet(
    context,
    title: 'Filter facilities',
    child: StatefulBuilder(
      builder: (context, sheetSetState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SrLabel('Category'),
          FilterSelect(
            value: categories.contains(_browseCategory)
                ? _browseCategory
                : 'All categories',
            items: ['All categories', ...categories],
            semanticLabel: 'Filter by category',
            onChanged: (value) {
              setState(() => _browseCategory = value);
              sheetSetState(() {});
            },
          ),
          const SizedBox(height: 14),
          const SrLabel('Minimum capacity'),
          FilterSelect(
            value: _capacityFilters.entries
                .firstWhere((entry) => entry.value == _minimumCapacity)
                .key,
            items: _capacityFilters.keys.toList(),
            semanticLabel: 'Filter by minimum capacity',
            onChanged: (value) {
              setState(() => _minimumCapacity = _capacityFilters[value]!);
              sheetSetState(() {});
            },
          ),
          const SizedBox(height: 16),
          const SrLabel('Amenities'),
          for (final amenity in amenities)
            CheckboxListTile(
              value: _browseAmenities.contains(amenity),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(amenity, style: sans(12.5)),
              onChanged: (_) {
                setState(() {
                  if (!_browseAmenities.remove(amenity)) {
                    _browseAmenities.add(amenity);
                  }
                });
                sheetSetState(() {});
              },
            ),
          const SizedBox(height: 10),
          SrButton(
            label: 'Show facilities',
            kind: SrButtonKind.primary,
            expand: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    ),
  );

  void _clearBrowseFilters() {
    _browseSearch.clear();
    setState(() {
      _browseQuery = '';
      _browseCategory = 'All categories';
      _minimumCapacity = 0;
      _browseAmenities.clear();
    });
  }

  bool _shouldShowBanner(Account account) =>
      _bannerDismissed == false &&
      (account.verification == VerificationState.pending ||
          account.verification == VerificationState.verified);

  String? _bannerKeyFor(Account account) => switch (account.verification) {
    VerificationState.pending =>
      'student.dismissed_verification_pending.${account.id}',
    VerificationState.verified =>
      'student.dismissed_verification_verified.${account.id}',
    VerificationState.rejected || VerificationState.none => null,
  };

  void _syncBannerDismissal(Account account) {
    final key = _bannerKeyFor(account);
    if (key == _bannerDismissalKey) return;
    _bannerDismissalKey = key;
    _bannerDismissed = key == null ? true : null;
    if (key != null) unawaited(_loadBannerDismissal(key));
  }

  Future<void> _loadBannerDismissal(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dismissed = prefs.getBool(key) ?? false;
      if (!mounted || _bannerDismissalKey != key) return;
      setState(() => _bannerDismissed = dismissed);
    } catch (_) {
      if (mounted && _bannerDismissalKey == key) {
        setState(() => _bannerDismissed = false);
      }
    }
  }

  Future<void> _dismissBanner() async {
    final key = _bannerDismissalKey;
    if (key == null) return;
    setState(() => _bannerDismissed = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, true);
    } catch (_) {}
  }

  Widget _mine(AppState state) {
    final rows = state.myRequests;
    final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
    if (rows.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 52),
        decoration: BoxDecoration(
          color: SR.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: SR.border),
        ),
        child: Column(
          children: [
            Text('No reservations yet', style: sans(14, w: 600)),
            const SizedBox(height: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                'Pick a facility from Browse. You will see its status here as '
                'the registrar decides.',
                textAlign: TextAlign.center,
                style: sans(12, height: 1.6, color: SR.ink4),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final request in rows)
          Container(
            margin: const EdgeInsets.only(bottom: 9),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
            decoration: BoxDecoration(
              color: SR.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: SR.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    Text(request.facility, style: sans(13, w: 600)),
                    Text(
                      '${request.building} · ${request.room}',
                      style: sans(11, color: SR.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                if (compact)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            request.whenLabel,
                            style: mono(11.5, w: 500, color: SR.ink3),
                          ),
                          Text(
                            '${request.heads} people',
                            style: mono(11, color: SR.muted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SrPill(
                        label: request.heldForVerification
                            ? 'Held — verification pending'
                            : request.status.label,
                        background: request.heldForVerification
                            ? SR.amberTint
                            : request.status.background,
                        foreground: request.heldForVerification
                            ? SR.amber
                            : request.status.foreground,
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              request.whenLabel,
                              style: mono(11.5, w: 500, color: SR.ink3),
                            ),
                            Text(
                              '${request.heads} people',
                              style: mono(11, color: SR.muted),
                            ),
                          ],
                        ),
                      ),
                      SrPill(
                        label: request.heldForVerification
                            ? 'Held — verification pending'
                            : request.status.label,
                        background: request.heldForVerification
                            ? SR.amberTint
                            : request.status.background,
                        foreground: request.heldForVerification
                            ? SR.amber
                            : request.status.foreground,
                      ),
                    ],
                  ),
                if (request.reason case final reason?) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: SR.surfaceSubtle,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: SR.hairline),
                    ),
                    child: Text(
                      '“$reason”',
                      style: sans(11.5, height: 1.6, color: SR.ink4),
                    ),
                  ),
                ],
                if (request.paymentStatus !=
                    PaymentTrackingStatus.notRequired) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${request.paymentStatus.label} · no real payment is processed',
                    style: sans(10.5, color: SR.muted),
                  ),
                ],
                if (request.occurrences.length > 1) ...[
                  const SizedBox(height: 10),
                  for (final occurrence in request.occurrences)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: compact
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${_reservationDate(occurrence.startsAt)} · '
                                  '${_reservationClock(occurrence.startsAt)}–'
                                  '${_reservationClock(occurrence.endsAt)}',
                                  style: mono(10.5, color: SR.ink3),
                                ),
                                const SizedBox(height: 5),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      occurrence.stage == BookingStage.noShow
                                          ? 'No-show'
                                          : occurrence.bookingState.replaceAll(
                                              '_',
                                              ' ',
                                            ),
                                      style: sans(
                                        10.5,
                                        w: 500,
                                        color: SR.muted,
                                      ),
                                    ),
                                    if (occurrence.startsAt.isAfter(
                                          campusNow(),
                                        ) &&
                                        !const [
                                          'cancelled',
                                          'expired',
                                        ].contains(occurrence.bookingState))
                                      SrButton(
                                        label: 'Cancel date',
                                        dense: true,
                                        fontSize: 10,
                                        onPressed: () =>
                                            state.cancelReservation(
                                              request,
                                              occurrenceId: occurrence.id,
                                            ),
                                      ),
                                  ],
                                ),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${_reservationDate(occurrence.startsAt)} · '
                                    '${_reservationClock(occurrence.startsAt)}–'
                                    '${_reservationClock(occurrence.endsAt)}',
                                    style: mono(10.5, color: SR.ink3),
                                  ),
                                ),
                                Text(
                                  occurrence.stage == BookingStage.noShow
                                      ? 'No-show'
                                      : occurrence.bookingState.replaceAll(
                                          '_',
                                          ' ',
                                        ),
                                  style: sans(10.5, w: 500, color: SR.muted),
                                ),
                                if (occurrence.startsAt.isAfter(campusNow()) &&
                                    !const [
                                      'cancelled',
                                      'expired',
                                    ].contains(occurrence.bookingState)) ...[
                                  const SizedBox(width: 6),
                                  SrButton(
                                    label: 'Cancel date',
                                    dense: true,
                                    fontSize: 10,
                                    onPressed: () => state.cancelReservation(
                                      request,
                                      occurrenceId: occurrence.id,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                    ),
                ],
                if (request.status == RequestStatus.changesRequested) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final occurrence in request.occurrences)
                        if (occurrence.proposedStartsAt != null)
                          SrButton(
                            label: 'Accept offered time',
                            kind: SrButtonKind.primary,
                            dense: true,
                            onPressed: () => state.acceptReservationAlternative(
                              request,
                              occurrence,
                            ),
                          ),
                      SrButton(
                        label: 'Edit and resubmit',
                        dense: true,
                        onPressed: () => _editAndResubmit(state, request),
                      ),
                    ],
                  ),
                ],
                if (request.status == RequestStatus.pending ||
                    request.status == RequestStatus.approved ||
                    request.status == RequestStatus.changesRequested) ...[
                  const SizedBox(height: 9),
                  SrButton(
                    label: request.occurrences.length > 1
                        ? 'Cancel all future dates'
                        : 'Cancel reservation',
                    kind: SrButtonKind.danger,
                    dense: true,
                    onPressed: () => state.cancelReservation(request),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _editAndResubmit(
    AppState state,
    ReservationRequest request,
  ) async {
    final purpose = TextEditingController(text: request.purpose);
    final heads = TextEditingController(text: '${request.heads}');
    final fallbackDate = campusNow().add(const Duration(days: 1));
    final occurrence = request.occurrences.isEmpty
        ? ReservationOccurrence(
            id: request.id,
            startsAt: DateTime(
              fallbackDate.year,
              fallbackDate.month,
              fallbackDate.day,
              request.startHour,
            ),
            endsAt: DateTime(
              fallbackDate.year,
              fallbackDate.month,
              fallbackDate.day,
              request.endHour,
            ),
            bookingState: 'changes_requested',
          )
        : request.occurrences.firstWhere(
            (item) => item.needsNewTime,
            orElse: () => request.occurrences.first,
          );
    var date = DateTime(
      occurrence.startsAt.year,
      occurrence.startsAt.month,
      occurrence.startsAt.day,
    );
    var startTime = TimeOfDay.fromDateTime(occurrence.startsAt);
    var endTime = TimeOfDay.fromDateTime(occurrence.endsAt);
    final campusTodayValue = campusNow();
    final today = DateTime(
      campusTodayValue.year,
      campusTodayValue.month,
      campusTodayValue.day,
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
          final buttonStyle = OutlinedButton.styleFrom(
            minimumSize: const Size(44, 44),
          );
          final fromButton = OutlinedButton(
            style: buttonStyle,
            onPressed: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: startTime,
              );
              if (picked != null) {
                setDialogState(() => startTime = picked);
              }
            },
            child: Text('From ${startTime.format(context)}'),
          );
          final toButton = OutlinedButton(
            style: buttonStyle,
            onPressed: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: endTime,
              );
              if (picked != null) setDialogState(() => endTime = picked);
            },
            child: Text('To ${endTime.format(context)}'),
          );
          return SrAdaptiveDialog(
            maxWidth: 540,
            maxHeight: 620,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 16 : 22,
                    compact ? 8 : 16,
                    compact ? 6 : 10,
                    compact ? 8 : 12,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Edit and resubmit',
                          style: sans(compact ? 18 : 19, w: 600),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        constraints: const BoxConstraints.tightFor(
                          width: 44,
                          height: 44,
                        ),
                        onPressed: () => Navigator.pop(context, false),
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: SR.border),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(compact ? 16 : 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: purpose,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: 'Purpose',
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: heads,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Attendees',
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          style: buttonStyle,
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: date.isBefore(today) ? today : date,
                              firstDate: today,
                              lastDate: today.add(const Duration(days: 365)),
                            );
                            if (picked != null) {
                              setDialogState(() => date = picked);
                            }
                          },
                          child: Text(_reservationDate(date)),
                        ),
                        const SizedBox(height: 8),
                        LayoutBuilder(
                          builder: (context, constraints) =>
                              constraints.maxWidth < 360
                              ? Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    fromButton,
                                    const SizedBox(height: 8),
                                    toButton,
                                  ],
                                )
                              : Row(
                                  children: [
                                    Expanded(child: fromButton),
                                    const SizedBox(width: 8),
                                    Expanded(child: toButton),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1, color: SR.border),
                Padding(
                  padding: EdgeInsets.all(compact ? 16 : 18),
                  child: compact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Resubmit'),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                            ),
                          ],
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            OutlinedButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Resubmit'),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (accepted == true) {
      final count = int.tryParse(heads.text.trim()) ?? 0;
      if (purpose.text.trim().isNotEmpty && count > 0) {
        state.resubmitReservation(
          request,
          purpose: purpose.text.trim(),
          headcount: count,
          occurrence: occurrence,
          startsAt: DateTime(
            date.year,
            date.month,
            date.day,
            startTime.hour,
            startTime.minute,
          ),
          endsAt: DateTime(
            date.year,
            date.month,
            date.day,
            endTime.hour,
            endTime.minute,
          ),
        );
      }
    }
    purpose.dispose();
    heads.dispose();
  }

  static String _reservationClock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  static String _reservationDate(DateTime value) {
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
    return '${value.day} ${months[value.month - 1]} ${value.year}';
  }

  Widget _account(AppState state, Account account) {
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 900;
    final compact = SR.isCompact(width);
    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Panel(
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Initials(
                          text: account.initials,
                          size: 46,
                          fontSize: 14,
                        ),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                account.name,
                                style: sans(16, w: 600, tracking: -.015),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                account.email,
                                style: mono(11, color: SR.muted),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Joined ${account.joined}',
                                style: mono(10.5, color: SR.muted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SrPill(
                        label: account.verification.label,
                        background: account.verification.background,
                        foreground: account.verification.foreground,
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Initials(text: account.initials, size: 46, fontSize: 14),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            account.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: sans(16, w: 600, tracking: -.015),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            account.email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: mono(11, color: SR.muted),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Joined ${account.joined}',
                            style: mono(10.5, color: SR.muted),
                          ),
                        ],
                      ),
                    ),
                    SrPill(
                      label: account.verification.label,
                      background: account.verification.background,
                      foreground: account.verification.foreground,
                    ),
                  ],
                ),
        ),
        _verificationPanel(state, account),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Your details', style: sans(12.5, w: 600)),
              const SizedBox(height: 2),
              Text(
                state.hasSession
                    ? 'These details come from your authenticated account and '
                          'verification submission.'
                    : 'Anything drawn from a verified document is fixed — '
                          're-submit to correct it.',
                style: sans(11, color: SR.muted),
              ),
              const SizedBox(height: 12),
              _detailsGrid(state, account),
            ],
          ),
        ),
      ],
    );

    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SrCellGrid(
          columns: 3,
          children: [
            SrKeyCell(label: 'REQUESTS', value: '${state.myRequests.length}'),
            SrKeyCell(
              label: 'APPROVED',
              value:
                  '${state.myRequests.where((r) => r.status == RequestStatus.approved).length}',
            ),
            SrKeyCell(label: 'NO-SHOWS', value: '${account.noShows}'),
          ],
        ),
        const SizedBox(height: 12),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Notifications', style: sans(12.5, w: 600)),
              const SizedBox(height: 13),
              for (final entry in state.notificationPreferences.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    children: [
                      Expanded(child: Text(entry.key, style: sans(12, w: 500))),
                      SrToggle(
                        value: entry.value,
                        label: entry.key,
                        onChanged: (v) =>
                            state.setNotificationPreference(entry.key, v),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Security', style: sans(12.5, w: 600)),
              const SizedBox(height: 12),
              SrCellGrid(
                columns: 1,
                children: const [
                  SrKeyCell(label: 'PASSWORD', value: 'Changed 3 months ago'),
                  SrKeyCell(label: 'SESSION', value: 'Expires in 30 days'),
                ],
              ),
              const SizedBox(height: 12),
              SrButton(
                label: 'Sign out',
                kind: SrButtonKind.danger,
                expand: true,
                minHeight: 42,
                fontSize: 12.5,
                onPressed: () => state.signOut(),
              ),
            ],
          ),
        ),
      ],
    );

    if (narrow) {
      return Column(children: [left, const SizedBox(height: 12), right]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 12),
        Expanded(child: right),
      ],
    );
  }

  Widget _verificationPanel(AppState state, Account account) {
    final (
      bg,
      border,
      accent,
      title,
      body,
      cta,
    ) = switch (account.verification) {
      VerificationState.verified => (
        SR.greenTint,
        const Color(0xFFB7E9CD),
        SR.greenDark,
        'Verified campus member',
        'You reserve free of charge, subject to the registrar approving '
            'the slot. Verification runs to the end of the academic year.',
        null,
      ),
      VerificationState.pending => (
        SR.amberTint,
        SR.amberLine,
        SR.amber,
        'Awaiting review',
        'Documents are reviewed each morning, usually within one business '
            'day. Requests you make now are held and released '
            'automatically.',
        null,
      ),
      VerificationState.rejected => (
        SR.redTint,
        SR.redLine,
        SR.red,
        'Campus claim not approved',
        'You can still reserve at the external rate. One appeal with a '
            'different document is allowed.',
        'Appeal with another document',
      ),
      VerificationState.none => (
        SR.blueTint2,
        SR.blueLine,
        SR.blueDark,
        'Booking as a guest',
        'Students and faculty of CSU Aparri reserve free. If that is you, '
            'verification takes about a minute.',
        'I am a campus member',
      ),
    };

    return _Panel(
      background: bg,
      border: border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: sans(13.5, w: 600, tracking: -.01, color: accent)),
          const SizedBox(height: 6),
          Text(body, style: sans(12, height: 1.65, color: SR.ink4)),
          if (cta != null) ...[
            const SizedBox(height: 13),
            SrButton(
              label: cta,
              kind: SrButtonKind.primary,
              fontSize: 12.5,
              minHeight: 40,
              onPressed: () => state.goTo(AppView.auth),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailsGrid(AppState state, Account account) {
    final locked = !state.userDetailsEditable;
    final lockedNote = state.hasSession
        ? 'From your authenticated account'
        : account.verification == VerificationState.verified
        ? 'From your verified document'
        : null;
    final rows = [
      _detailRow(
        state,
        label: 'FULL NAME',
        field: 'name',
        value: account.name,
        locked: locked,
        lockedNote: lockedNote,
      ),
      _detailRow(
        state,
        label: 'ID NUMBER',
        field: 'idNumber',
        value: account.idNumber,
        locked: locked,
        lockedNote: lockedNote,
        valueMono: true,
      ),
      _detailRow(
        state,
        label: 'PROGRAMME / UNIT',
        field: 'unit',
        value: account.unit,
        locked: locked,
        lockedNote: lockedNote,
      ),
      _detailRow(
        state,
        label: 'ROLE',
        field: 'role',
        value: account.role.label,
        locked: true,
        lockedNote: lockedNote,
      ),
    ];
    return Container(
      decoration: BoxDecoration(
        color: SR.hairline,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SR.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 1),
            rows[i],
          ],
        ],
      ),
    );
  }

  Widget _detailRow(
    AppState state, {
    required String label,
    required String field,
    required String value,
    required bool locked,
    String? lockedNote,
    bool valueMono = false,
  }) {
    final editing = _editingField == field;
    return Container(
      color: SR.surface,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: editing
                ? SrTextField(
                    controller: _editController,
                    semanticLabel: label,
                    mono: valueMono,
                    fontSize: 12.5,
                    autofocus: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 7,
                    ),
                    onSubmitted: (_) => _saveDetail(state, field),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label, style: keyLabel),
                      const SizedBox(height: 4),
                      Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: valueMono
                            ? mono(12.5, w: 500)
                            : sans(12.5, w: 500),
                      ),
                      if (locked && lockedNote != null) ...[
                        const SizedBox(height: 2),
                        Text(lockedNote, style: sans(10.5, color: SR.muted)),
                      ],
                    ],
                  ),
          ),
          if (editing) ...[
            const SizedBox(width: 8),
            SrButton(
              label: 'Cancel',
              dense: true,
              fontSize: 11,
              onPressed: () => setState(() => _editingField = null),
            ),
            const SizedBox(width: 6),
            SrButton(
              label: 'Save',
              kind: SrButtonKind.primary,
              dense: true,
              fontSize: 11,
              onPressed: () => _saveDetail(state, field),
            ),
          ] else if (!locked) ...[
            const SizedBox(width: 8),
            SrButton(
              label: 'Edit',
              dense: true,
              fontSize: 11,
              onPressed: () {
                _editController.text = value;
                setState(() => _editingField = field);
              },
            ),
          ],
        ],
      ),
    );
  }

  void _saveDetail(AppState state, String field) {
    state.updateUserDetail(field, _editController.text);
    setState(() => _editingField = null);
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.selected,
    required this.onSelect,
    required this.onOpenAssistant,
  });

  final StudentTab selected;
  final ValueChanged<StudentTab> onSelect;
  final VoidCallback onOpenAssistant;

  static const _pillTabs = [
    StudentTab.browse,
    StudentTab.mine,
    StudentTab.account,
  ];

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              height: 58,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: SR.surface,
                borderRadius: BorderRadius.circular(29),
                border: Border.all(color: SR.border),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x1F10141A),
                    blurRadius: 20,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                children: [
                  for (final tab in _pillTabs)
                    Expanded(
                      child: _BottomNavItem(
                        tab: tab,
                        selected: tab == selected,
                        onTap: () => onSelect(tab),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          _AssistantButton(
            key: const Key('student-assistant-tab'),
            onTap: onOpenAssistant,
          ),
        ],
      ),
    ),
  );
}

/// Opens the assistant as a pushed screen (see [AssistantChatPage]) rather
/// than selecting a tab, so it always sits in the same tinted resting
/// state — there is no "currently selected" state to reflect once it is
/// its own route.
class _AssistantButton extends StatelessWidget {
  const _AssistantButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Assistant',
    child: Hoverable(
      builder: (context, hovered) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: SR.stateChange,
          width: 58,
          height: 58,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hovered ? SR.blue : SR.blueTint,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: hovered ? const Color(0x3B2F6FED) : const Color(0x1F10141A),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Icon(
            Icons.auto_awesome_rounded,
            size: 22,
            color: hovered ? SR.surface : SR.blue,
          ),
        ),
      ),
    ),
  );
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final StudentTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? SR.blue : SR.ink4;
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(tab.icon, size: 21, color: color),
            const SizedBox(height: 3),
            Text(tab.short, style: sans(10.5, w: 600, color: color)),
          ],
        ),
      ),
    );
  }
}

class _AmenitiesFilter extends StatelessWidget {
  const _AmenitiesFilter({
    required this.amenities,
    required this.selected,
    required this.onToggle,
  });

  final List<String> amenities;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Filter by amenities',
    onSelected: onToggle,
    color: SR.surface,
    position: PopupMenuPosition.under,
    constraints: const BoxConstraints(maxHeight: 360, minWidth: 220),
    itemBuilder: (context) => [
      for (final amenity in amenities)
        PopupMenuItem<String>(
          value: amenity,
          child: Row(
            children: [
              Icon(
                selected.contains(amenity)
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 18,
                color: selected.contains(amenity) ? SR.blue : SR.muted,
              ),
              const SizedBox(width: 9),
              Expanded(child: Text(amenity, style: sans(11.5, w: 500))),
            ],
          ),
        ),
    ],
    child: Semantics(
      button: true,
      label: 'Filter by amenities',
      child: Container(
        height: 36,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: selected.isEmpty ? SR.surface : SR.blueTint,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: selected.isEmpty ? SR.border : SR.blueSoft),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                selected.isEmpty
                    ? 'Amenities'
                    : 'Amenities (${selected.length})',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sans(11.5, w: 500, color: SR.ink3),
              ),
            ),
            const SizedBox(width: 7),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: SR.muted,
            ),
          ],
        ),
      ),
    ),
  );
}

class _BrowseEmpty extends StatelessWidget {
  const _BrowseEmpty({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 44),
    decoration: BoxDecoration(
      color: SR.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SR.border),
    ),
    child: Column(
      children: [
        Text('No facilities match', style: sans(14, w: 600)),
        const SizedBox(height: 5),
        Text(
          'Try a different search, capacity, category, or amenity.',
          textAlign: TextAlign.center,
          style: sans(12, height: 1.6, color: SR.ink4),
        ),
        const SizedBox(height: 14),
        SrButton(label: 'Clear filters', onPressed: onClear),
      ],
    ),
  );
}

class _FacilityCard extends StatelessWidget {
  const _FacilityCard({
    required this.facility,
    required this.free,
    required this.quote,
    required this.onTap,
  });

  final Facility facility;
  final bool free;
  final int quote;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Hoverable(
    builder: (context, hovered) => GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: SR.stateChange,
        clipBehavior: Clip.antiAlias,
        transform: Matrix4.translationValues(0, hovered ? -2 : 0, 0),
        decoration: BoxDecoration(
          color: SR.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: hovered ? SR.blueSoft : SR.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 118,
              child: facility.coverPhoto == null
                  ? const PlaceholderStripes(
                      hue: 215,
                      caption: 'photo pending',
                      captionSize: 10,
                    )
                  : FacilityPhotoImage(photo: facility.coverPhoto!),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      facility.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(13, w: 600, tracking: -.01),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      facility.building,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sans(11, color: SR.muted),
                    ),
                    const Spacer(),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Expanded(
                          child: Text(
                            facility.category,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: sans(11, color: SR.ink3),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${facility.capacity} seats',
                          style: mono(10.5, color: SR.muted),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          free ? 'Free' : '₱$quote / 2 h',
                          style: sans(
                            11.5,
                            w: 600,
                            color: free ? SR.greenDark : SR.ink,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.child,
    this.background = SR.surface,
    this.border = SR.border,
  });

  final Widget child;
  final Color background;
  final Color border;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: border),
    ),
    child: child,
  );
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.background,
    required this.border,
    required this.foreground,
    required this.title,
    required this.body,
    required this.onDismiss,
  });

  final Color background;
  final Color border;
  final Color foreground;
  final String title;
  final String body;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: sans(12.5, w: 600, color: foreground)),
            ),
            SrIconButton(
              icon: Icons.close_rounded,
              tooltip: 'Dismiss membership message',
              size: 26,
              fontSize: 10,
              background: Colors.transparent,
              border: null,
              foreground: foreground,
              hoverForeground: foreground,
              onPressed: onDismiss,
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(body, style: sans(11.5, height: 1.6, color: SR.ink4)),
      ],
    ),
  );
}
