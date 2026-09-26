import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../app/app_view.dart';
import '../../model/account.dart';
import '../../model/facility.dart';
import '../../model/notice.dart';
import '../../model/payment.dart';
import '../../model/reservation.dart';
import '../../theme/sr_tokens.dart';
import '../../theme/sr_theme.dart';
import '../../util/campus_calendar.dart';
import '../reservations/permit_panel.dart';
import '../../widgets/amenity_request_field.dart';
import '../../widgets/evidence_thumbnails.dart';
import '../../widgets/facility_catalogue_card.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/rating_display.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_assistant_logo.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';
import '../assistant/assistant_ai_client.dart';
import '../assistant/assistant_chat_page.dart';
import '../assistant/assistant_controller.dart';
import '../calendar/calendar_screen.dart';
import 'booking_sheet.dart';
import 'facility_preview.dart';
import 'feedback_dialog.dart';
import 'payment_proof_sheet.dart';
import 'loyalty_page.dart';

enum StudentTab {
  browse('Browse', 'Browse', Icons.grid_view_outlined, Icons.grid_view_rounded),
  calendar(
    'Calendar',
    'Calendar',
    Icons.calendar_month_outlined,
    Icons.calendar_month_rounded,
  ),
  mine(
    'My reservations',
    'Reservation',
    Icons.book_online_outlined,
    Icons.book_online_rounded,
  ),
  account(
    'Account',
    'Account',
    Icons.person_outline_rounded,
    Icons.person_rounded,
  );

  const StudentTab(this.label, this.short, this.icon, this.selectedIcon);

  final String label;

  final String short;
  final IconData icon;

  final IconData selectedIcon;
}

class StudentApp extends StatefulWidget {
  const StudentApp({super.key});

  @override
  State<StudentApp> createState() => _StudentAppState();
}

class _StudentAppState extends State<StudentApp> {
  StudentTab _tab = StudentTab.browse;

  /// Set from a `feedback_reply` notification tap so `_mine()` can draw
  /// attention to the reservation the reply landed on. Left set for the
  /// rest of this session rather than cleared on tap -- the cards here
  /// hold their own buttons, and wrapping the whole card in a tap handler
  /// would fight the gesture arena with those.
  String? _highlightedReservationId;

  String? _editingField;
  bool _pushBusy = false;
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

  String _timeGreeting([DateTime? now]) {
    final hour = (now ?? DateTime.now()).hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  void initState() {
    super.initState();
    _assistant = AssistantController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncBannerDismissal(AppScope.of(context).userAccount);
    final state = AppScope.of(context);
    // Attached once a real backend exists. Without one the assistant keeps
    // answering from rules alone, which is the whole fallback guarantee.
    final backend = state.backend;
    _assistant.aiClient = backend == null
        ? null
        : SupabaseAssistantAiClient(backend);
    if (state.pendingLoyaltyOpen) {
      state.pendingLoyaltyOpen = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(state.refreshLoyalty());
        _openLoyalty(context);
      });
    }
    if (state.pendingReservationFocusId case final focusId?) {
      state.pendingReservationFocusId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        // The reply itself rides on the reservation embed, which is only
        // fetched once by refreshReservations() -- unlike app_notifications,
        // it is not realtime-subscribed. Without this refresh a renter
        // sitting in the app sees the notification but a stale card.
        await state.refreshReservations();
        if (!mounted) return;
        setState(() {
          _tab = StudentTab.mine;
          _highlightedReservationId = focusId;
        });
      });
    }
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
      color: context.srColors.bg,
      child: Column(
        children: [
          _header(state, account, narrow),
          Expanded(
            child: switch (_tab) {
              StudentTab.browse => _scrollable(
                _browse(state, account),
                width,
                narrow,
                key: const ValueKey(StudentTab.browse),
              ),
              StudentTab.mine => _scrollable(
                _mine(state),
                width,
                narrow,
                key: const ValueKey(StudentTab.mine),
              ),
              StudentTab.calendar => const PublicCalendarScreen(
                key: ValueKey(StudentTab.calendar),
              ),
              StudentTab.account => _scrollable(
                _account(state, account),
                width,
                narrow,
                key: const ValueKey(StudentTab.account),
                fullWidth: true,
              ),
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

  Future<void> _openAssistant(BuildContext context) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AssistantChatPage(controller: _assistant),
        ),
      );

  Future<void> _openLoyalty(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => const LoyaltyPage()));

  Widget _scrollable(
    Widget child,
    double width,
    bool narrow, {
    Key? key,
    bool fullWidth = false,
  }) => SrScrollView(
    key: key,
    padding: SR.pageInsets(width, top: narrow ? 14 : 20),
    child: fullWidth
        ? SizedBox(width: double.infinity, child: child)
        : Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: child,
            ),
          ),
  );

  Widget _header(AppState state, Account account, bool narrow) {
    final tiny = MediaQuery.sizeOf(context).width < 340;
    return Container(
      padding: EdgeInsets.fromLTRB(
        narrow ? 16 : 24,
        narrow ? 16 : 20,
        narrow ? 16 : 24,
        _tab == StudentTab.browse ? 20 : 16,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: context.srColors.isDark
              ? const [Color(0xFF0C2742), Color(0xFF123551)]
              : const [Color(0xFF1A73E8), Color(0xFF1479B8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        // borderRadius: BorderRadius.vertical(bottom: Radius.circular(0)),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (tiny)
                        Text(
                          account.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: sans(
                            17,
                            w: 600,
                            tracking: -.02,
                            color: Colors.white,
                          ),
                        )
                      else
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                account.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: sans(
                                  narrow ? 18 : 21,
                                  w: 600,
                                  tracking: -.02,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      const SizedBox(height: 2),
                      Text(
                        _timeGreeting(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono(10, color: SR.onDarkMuted),
                      ),
                    ],
                  ),
                ),
                if (state.loyaltyAvailableForCurrentUser) ...[
                  InkWell(
                    key: const Key('student-loyalty-chip'),
                    borderRadius: BorderRadius.circular(SR.rFull),
                    onTap: () => _openLoyalty(context),
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: narrow ? 7 : 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .16),
                        borderRadius: BorderRadius.circular(SR.rFull),
                        border: Border.all(color: SR.onDarkLine),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.stars_rounded,
                            size: 15,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${state.loyalty?.balance ?? 0}',
                            style: mono(11, w: 600, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(width: narrow ? 2 : 6),
                ],
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconButton(
                      tooltip: 'Notifications',
                      color: Colors.white,
                      onPressed: () => _showNotifications(state),
                      icon: const Icon(
                        Icons.notifications_none_rounded,
                        size: 22,
                      ),
                    ),
                    if (state.unreadNotifications > 0)
                      Positioned(
                        right: 1,
                        top: 1,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: SR.redBright,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${state.unreadNotifications}',
                            style: mono(8.5, w: 600, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(width: narrow ? 2 : 6),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: narrow ? 5 : 9,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .16),
                    borderRadius: BorderRadius.circular(SR.rFull),
                    border: Border.all(color: SR.onDarkLine),
                  ),
                  child: Text(switch (account.verification) {
                    VerificationState.verified => 'VERIFIED',
                    VerificationState.pending => 'IN PROCESS',
                    VerificationState.rejected => 'NOT VERIFIED',
                    VerificationState.none => 'RENTER',
                  }, style: mono(8.5, w: 600, color: Colors.white)),
                ),
              ],
            ),
            if (_tab == StudentTab.browse) ...[
              const SizedBox(height: 16),
              Container(
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x220B1B33),
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: TextField(
                  controller: _browseSearch,
                  onChanged: (value) => setState(() => _browseQuery = value),
                  style: sans(13, color: SR.neutralDark),
                  cursorColor: SR.primary,
                  decoration: InputDecoration(
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: 'Search facilities, buildings, or amenities',
                    hintStyle: sans(12, color: const Color(0xFF7B8CA1)),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      color: SR.primary,
                    ),
                    suffixIcon: _browseQuery.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              _browseSearch.clear();
                              setState(() => _browseQuery = '');
                            },
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Color(0xFF60748A),
                            ),
                          ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

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
                          style: sans(12, color: context.srColors.muted),
                        ),
                      )
                    : ListView.separated(
                        itemCount: state.notifications.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = state.notifications[index];
                          return ListTile(
                            tileColor: item.unread
                                ? context.srColors.primaryTint
                                : null,
                            title: Text(
                              item.title,
                              style: sans(12.5, w: item.unread ? 600 : 500),
                            ),
                            subtitle: Text(
                              item.body,
                              style: sans(
                                11,
                                height: 1.45,
                                color: context.srColors.ink4,
                              ),
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
    final browsable = state.browsableFacilities;
    final categories = {
      for (final facility in browsable) facility.category,
    }.toList()..sort();
    final amenities = {
      for (final facility in browsable) ...facility.amenities,
    }.toList()..sort();
    final effectiveCategory = categories.contains(_browseCategory)
        ? _browseCategory
        : 'All categories';
    final availableAmenities = amenities.toSet();
    final effectiveAmenities = _browseAmenities.intersection(
      availableAmenities,
    );
    final visible = state.searchBrowsableFacilities(
      query: _browseQuery,
      category: effectiveCategory,
      minCapacity: _minimumCapacity,
      amenities: effectiveAmenities,
    );
    final filtersActive =
        _browseQuery.trim().isNotEmpty ||
        effectiveCategory != 'All categories' ||
        _minimumCapacity > 0 ||
        effectiveAmenities.isNotEmpty;
    final narrow = SR.isCompact(MediaQuery.sizeOf(context).width);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_shouldShowBanner(account))
          _Banner(
            background: account.verification == VerificationState.pending
                ? context.srColors.amberTint
                : context.srColors.greenTint,
            border: account.verification == VerificationState.pending
                ? context.srColors.amberLine
                : context.srColors.greenLine,
            foreground: account.verification == VerificationState.pending
                ? context.srColors.amberTitle
                : context.srColors.greenDark,
            title: account.verification == VerificationState.pending
                ? 'Verification in process'
                : 'You are verified',
            body: account.verification == VerificationState.pending
                ? 'You can browse facilities and send reservation requests now. '
                      'Requests sent now stay in the external administrator lane. '
                      'New requests use the internal lane after verification.'
                : 'Your campus membership is confirmed. Browse facilities and '
                      'send reservation requests whenever you are ready.',
            onDismiss: _dismissBanner,
          ),
        const SizedBox(height: 8),
        if (state.facilitiesLoading && browsable.isEmpty)
          const _BrowseStatus.loading()
        else if (state.facilitiesError != null && browsable.isEmpty)
          _BrowseStatus.error(
            message: state.facilitiesError!,
            onAction: () => unawaited(state.refreshFacilities()),
          )
        else if (browsable.isEmpty)
          const _BrowseStatus.empty()
        else ...[
          if (state.facilitiesError != null)
            _BrowseRefreshWarning(
              message: state.facilitiesError!,
              onRetry: () => unawaited(state.refreshFacilities()),
            ),
          _categoryShortcuts(categories, selected: effectiveCategory),
          const SizedBox(height: 12),
          _browseFilters(
            narrow: narrow,
            categories: categories,
            amenities: amenities,
            selectedCategory: effectiveCategory,
            selectedAmenities: effectiveAmenities,
            filtersActive: filtersActive,
          ),
          if (visible.isEmpty)
            _BrowseStatus.noMatch(onAction: _clearBrowseFilters)
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = ((constraints.maxWidth + 12) / 300)
                    .floor()
                    .clamp(1, 3)
                    .toInt();
                final cardWidth =
                    (constraints.maxWidth - (12 * (columns - 1))) / columns;
                final cardHeight = cardWidth / (16 / 10) + 335;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemCount: visible.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    mainAxisExtent: cardHeight,
                  ),
                  itemBuilder: (context, index) {
                    final facility = visible[index];
                    final reserveEnabled =
                        facility.state == FacilityState.active &&
                        facility.bookableForCurrentUser;
                    final availabilityLabel = _facilityAvailabilityLabelFor(
                      facility,
                    );
                    return FacilityCatalogueCard(
                      data: _cardDataFromFacility(
                        facility,
                        account.pricingAudience,
                      ),
                      showRate:
                          account.verification != VerificationState.verified,
                      reserveEnabled: reserveEnabled,
                      reserveTooltip: reserveEnabled
                          ? 'Reserve now for ${facility.name}'
                          : availabilityLabel,
                      onViewDetails: () => showFacilityPreview(
                        context,
                        state: state,
                        facility: facility,
                        reserveEnabled: reserveEnabled,
                        reserveReason:
                            _facilityAdminUnavailabilityExplanationFor(
                              facility,
                            ) ??
                            availabilityLabel,
                        onReserve: (reserveContext) => showBookingSheet(
                          reserveContext,
                          state: state,
                          facility: facility,
                        ),
                      ),
                      onReserve: () => showFacilityPreview(
                        context,
                        state: state,
                        facility: facility,
                        reserveEnabled: reserveEnabled,
                        reserveReason:
                            _facilityAdminUnavailabilityExplanationFor(
                              facility,
                            ) ??
                            availabilityLabel,
                        onReserve: (reserveContext) => showBookingSheet(
                          reserveContext,
                          state: state,
                          facility: facility,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
        ],
      ],
    );
  }

  Widget _browseFilters({
    required bool narrow,
    required List<String> categories,
    required List<String> amenities,
    required String selectedCategory,
    required Set<String> selectedAmenities,
    required bool filtersActive,
  }) {
    final category = FilterSelect(
      value: selectedCategory,
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
      selected: selectedAmenities,
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
        child: Row(
          children: [
            Expanded(
              child: Text(
                filtersActive
                    ? 'Filtered facility results'
                    : 'All public facilities',
                style: sans(12, w: 600, color: context.srColors.ink3),
              ),
            ),
            if (filtersActive) clear,
            const SizedBox(width: SR.space8),
            CompactFilterButton(
              activeCount:
                  (selectedCategory == 'All categories' ? 0 : 1) +
                  (_minimumCapacity == 0 ? 0 : 1) +
                  (selectedAmenities.isEmpty ? 0 : 1),
              onPressed: () => _showBrowseFilters(categories, amenities),
            ),
          ],
        ),
      );
    }

    return FilterBar(
      children: [
        SizedBox(width: 200, child: category),
        SizedBox(width: 200, child: capacity),
        SizedBox(width: 200, child: amenity),
        if (filtersActive) clear,
      ],
    );
  }

  Widget _categoryShortcuts(
    List<String> categories, {
    required String selected,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text('Categories', style: sans(13, w: 600))),
          Text(
            '${categories.length} available',
            style: mono(9.5, color: context.srColors.muted),
          ),
        ],
      ),
      const SizedBox(height: 9),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _CategoryShortcut(
              label: 'All',
              icon: Icons.apps_rounded,
              selected: selected == 'All categories',
              onTap: () => setState(() => _browseCategory = 'All categories'),
            ),
            for (final category in categories)
              _CategoryShortcut(
                label: category,
                icon: _categoryIcon(category),
                selected: selected == category,
                onTap: () => setState(() => _browseCategory = category),
              ),
          ],
        ),
      ),
    ],
  );

  IconData _categoryIcon(String category) {
    final value = category.toLowerCase();
    if (value.contains('laboratory') || value.contains('lab')) {
      return Icons.science_rounded;
    }
    if (value.contains('court') || value.contains('gym')) {
      return Icons.sports_basketball_rounded;
    }
    if (value.contains('auditorium') || value.contains('event')) {
      return Icons.campaign_rounded;
    }
    return Icons.meeting_room_rounded;
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
          color: context.srColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.srColors.border),
        ),
        child: Column(
          children: [
            Text('No reservations yet', style: sans(14, w: 600)),
            const SizedBox(height: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                'Pick a facility from Browse. You will see its status here as '
                'the assigned facility administrator decides.',
                textAlign: TextAlign.center,
                style: sans(12, height: 1.6, color: context.srColors.ink4),
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
              color: request.id == _highlightedReservationId
                  ? context.srColors.primaryTint
                  : context.srColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: request.id == _highlightedReservationId
                    ? context.srColors.primaryLine
                    : context.srColors.border,
              ),
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
                      style: sans(11, color: context.srColors.muted),
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
                            style: mono(
                              11.5,
                              w: 500,
                              color: context.srColors.ink3,
                            ),
                          ),
                          Text(
                            '${request.heads} people',
                            style: mono(11, color: context.srColors.muted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SrPill(
                        label: request.heldForVerification
                            ? 'Held — verification pending'
                            : request.lifecycleStatus.label,
                        background: request.heldForVerification
                            ? context.srColors.amberTint
                            : request.lifecycleStatus.background,
                        foreground: request.heldForVerification
                            ? context.srColors.amber
                            : request.lifecycleStatus.foreground,
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
                              style: mono(
                                11.5,
                                w: 500,
                                color: context.srColors.ink3,
                              ),
                            ),
                            Text(
                              '${request.heads} people',
                              style: mono(11, color: context.srColors.muted),
                            ),
                          ],
                        ),
                      ),
                      SrPill(
                        label: request.heldForVerification
                            ? 'Held — verification pending'
                            : request.lifecycleStatus.label,
                        background: request.heldForVerification
                            ? context.srColors.amberTint
                            : request.lifecycleStatus.background,
                        foreground: request.heldForVerification
                            ? context.srColors.amber
                            : request.lifecycleStatus.foreground,
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
                      color: context.srColors.surfaceSubtle,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: context.srColors.hairline),
                    ),
                    child: Text(
                      '“$reason”',
                      style: sans(
                        11.5,
                        height: 1.6,
                        color: context.srColors.ink4,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 9),
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  children: _progressSteps(request),
                ),
                if (request.totalAmountCentavos > 0) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: context.srColors.surfaceSubtle,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: context.srColors.hairline),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${request.aggregatePaymentStatus.label} · '
                          '${pesoFromCentavos(request.outstandingAmountCentavos)} remaining of '
                          '${pesoFromCentavos(request.totalAmountCentavos)} '
                          '(${request.downPaymentPercent}% down payment policy)',
                          style: sans(
                            10.5,
                            w: 500,
                            color: context.srColors.ink3,
                          ),
                        ),
                        if (request.paymentDueAt case final due?)
                          Text(
                            'Payment proof due ${_reservationDate(campusWallTime(due))} · '
                            '${_reservationClock(campusWallTime(due))}',
                            style: sans(10.5, color: context.srColors.muted),
                          ),
                        if (request.balanceDueAt case final due?)
                          Text(
                            'Remaining balance due ${_reservationDate(campusWallTime(due))} · '
                            '${_reservationClock(campusWallTime(due))}',
                            style: sans(10.5, color: context.srColors.muted),
                          ),
                        if (request.priceLines.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          for (final line in request.priceLines)
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    line.label,
                                    style: sans(
                                      10.5,
                                      color: context.srColors.muted,
                                    ),
                                  ),
                                ),
                                Text(
                                  pesoFromCentavos(line.totalCentavos),
                                  style: mono(
                                    10.5,
                                    color: context.srColors.ink3,
                                  ),
                                ),
                              ],
                            ),
                        ],
                        if (request.paymentTransactions.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          for (final payment in request.paymentTransactions)
                            Text(
                              '${payment.purpose.label}: '
                              '${pesoFromCentavos(payment.amountCentavos)} · '
                              '${payment.status.label} · Ref ${payment.referenceNumber}',
                              style: sans(10.5, color: context.srColors.muted),
                            ),
                        ],
                        if (request.paymentTransactions.any(
                          (payment) =>
                              payment.status ==
                              PaymentDecisionStatus.needsCorrection,
                        )) ...[
                          const SizedBox(height: 8),
                          for (final payment in request.paymentTransactions)
                            if (payment.status ==
                                PaymentDecisionStatus.needsCorrection)
                              Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.all(9),
                                decoration: BoxDecoration(
                                  color: context.srColors.amberTint,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Down payment pending correction',
                                      style: sans(
                                        12.5,
                                        w: 600,
                                        color: context.srColors.amberTitle,
                                      ),
                                    ),
                                    if (payment.rejectionReason != null)
                                      Text(
                                        'Reason: ${payment.rejectionReason}',
                                        style: sans(
                                          11.5,
                                          color: context.srColors.amberTitle,
                                        ),
                                      ),
                                    if (payment.correctionDueAt != null)
                                      Text(
                                        'Correct by: ${formatStamp(campusWallTime(payment.correctionDueAt!))}',
                                        style: sans(
                                          11.5,
                                          color: context.srColors.amberTitle,
                                        ),
                                      ),
                                    const SizedBox(height: 6),
                                    SrButton(
                                      label: 'Fix payment proof',
                                      kind: SrButtonKind.primary,
                                      dense: true,
                                      onPressed:
                                          state.reservationActionsPending
                                              .contains('payment:${payment.id}')
                                          ? null
                                          : () => _submitPayment(
                                              state,
                                              request,
                                              correctingPayment: payment,
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                        ],
                        if (request.outstandingAmountCentavos > 0 &&
                            !request.paymentTransactions.any(
                              (payment) =>
                                  payment.status ==
                                      PaymentDecisionStatus.submitted ||
                                  payment.status ==
                                      PaymentDecisionStatus.needsCorrection,
                            ) &&
                            (request.lifecycleStatus ==
                                    ReservationLifecycleStatus
                                        .awaitingPayment ||
                                request.lifecycleStatus ==
                                    ReservationLifecycleStatus.confirmed)) ...[
                          const SizedBox(height: 8),
                          SrButton(
                            label:
                                state.reservationActionsPending.contains(
                                  'payment:${request.id}',
                                )
                                ? 'Submitting…'
                                : 'Submit payment proof',
                            kind: SrButtonKind.primary,
                            dense: true,
                            onPressed:
                                state.reservationActionsPending.contains(
                                  'payment:${request.id}',
                                )
                                ? null
                                : () => _submitPayment(state, request),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                if (request.lifecycleStatus ==
                        ReservationLifecycleStatus.confirmed ||
                    request.permit != null) ...[
                  const SizedBox(height: 8),
                  PermitPanel(state: state, request: request),
                ],
                ..._selfCheckInRows(state, request),
                if (request.amenities.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Requested amenities',
                    style: sans(10.5, w: 500, color: context.srColors.ink4),
                  ),
                  const SizedBox(height: 5),
                  AmenityPills(request.amenities),
                ],
                if (request.acceptedTerms.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Terms accepted · ${request.acceptedTerms.map((term) => '${term.title} v${term.version}').join(' · ')}',
                    style: sans(10.5, color: context.srColors.muted),
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
                                  style: mono(
                                    10.5,
                                    color: context.srColors.ink3,
                                  ),
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
                                        color: context.srColors.muted,
                                      ),
                                    ),
                                    if (state.canRequestOccurrenceReschedule(
                                      request,
                                      occurrence,
                                    ))
                                      SrButton(
                                        label: state.reservationActionsPending
                                                .contains(request.id)
                                            ? 'Sending…'
                                            : 'Move date',
                                        dense: true,
                                        fontSize: 10,
                                        onPressed: state
                                                .reservationActionsPending
                                                .contains(request.id)
                                            ? null
                                            : () => _requestReschedule(
                                                state,
                                                request,
                                                occurrence,
                                              ),
                                      ),
                                    if (state.canCancelOccurrence(
                                      request,
                                      occurrence,
                                    ))
                                      SrButton(
                                        label:
                                            state.reservationActionsPending
                                                .contains(request.id)
                                            ? 'Cancelling…'
                                            : 'Cancel date',
                                        dense: true,
                                        fontSize: 10,
                                        onPressed:
                                            state.reservationActionsPending
                                                .contains(request.id)
                                            ? null
                                            : () async {
                                                await state.cancelReservation(
                                                  request,
                                                  occurrenceId: occurrence.id,
                                                );
                                              },
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
                                    style: mono(
                                      10.5,
                                      color: context.srColors.ink3,
                                    ),
                                  ),
                                ),
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
                                    color: context.srColors.muted,
                                  ),
                                ),
                                if (state.canRequestOccurrenceReschedule(
                                  request,
                                  occurrence,
                                )) ...[
                                  const SizedBox(width: 6),
                                  SrButton(
                                    label: state.reservationActionsPending
                                            .contains(request.id)
                                        ? 'Sending…'
                                        : 'Move date',
                                    dense: true,
                                    fontSize: 10,
                                    onPressed: state.reservationActionsPending
                                            .contains(request.id)
                                        ? null
                                        : () => _requestReschedule(
                                            state,
                                            request,
                                            occurrence,
                                          ),
                                  ),
                                ],
                                if (state.canCancelOccurrence(
                                  request,
                                  occurrence,
                                )) ...[
                                  const SizedBox(width: 6),
                                  SrButton(
                                    label:
                                        state.reservationActionsPending
                                            .contains(request.id)
                                        ? 'Cancelling…'
                                        : 'Cancel date',
                                    dense: true,
                                    fontSize: 10,
                                    onPressed:
                                        state.reservationActionsPending
                                            .contains(request.id)
                                        ? null
                                        : () async {
                                            await state.cancelReservation(
                                              request,
                                              occurrenceId: occurrence.id,
                                            );
                                          },
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
                if ((request.occurrences.length == 1 &&
                        state.canRequestReservationReschedule(request)) ||
                    state.canCancelReservation(request)) ...[
                  const SizedBox(height: 9),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      if (request.occurrences.length == 1 &&
                          state.canRequestOccurrenceReschedule(
                            request,
                            request.occurrences.first,
                          ))
                        SrButton(
                          label: state.reservationActionsPending.contains(
                            request.id,
                          )
                              ? 'Sending…'
                              : 'Request reschedule',
                          dense: true,
                          onPressed: state.reservationActionsPending.contains(
                            request.id,
                          )
                              ? null
                              : () => _requestReschedule(
                                  state,
                                  request,
                                  request.occurrences.first,
                                ),
                        ),
                      if (state.canCancelReservation(request))
                        SrButton(
                          label: state.reservationActionsPending.contains(
                            request.id,
                          )
                              ? 'Cancelling…'
                              : request.occurrences.length > 1
                              ? 'Cancel all future dates'
                              : 'Cancel reservation',
                          kind: SrButtonKind.danger,
                          dense: true,
                          onPressed: state.reservationActionsPending.contains(
                            request.id,
                          )
                              ? null
                              : () async {
                                  await state.cancelReservation(request);
                                },
                        ),
                    ],
                  ),
                ],
                _feedbackSection(state, request),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _progressSteps(ReservationRequest request) {
    Widget step(String label, bool done) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          done ? Icons.check_circle_rounded : Icons.circle_outlined,
          size: 12,
          color: done ? SR.green : context.srColors.muted,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: sans(
            10.5,
            w: 500,
            color: done ? context.srColors.ink3 : context.srColors.muted,
          ),
        ),
      ],
    );

    final terminal = {
      ReservationLifecycleStatus.declined,
      ReservationLifecycleStatus.cancelled,
      ReservationLifecycleStatus.expired,
    }.contains(request.lifecycleStatus);
    if (terminal) return const [];

    final approved =
        request.lifecycleStatus != ReservationLifecycleStatus.pendingApproval &&
        request.lifecycleStatus != ReservationLifecycleStatus.changesRequested;
    final confirmed =
        request.lifecycleStatus == ReservationLifecycleStatus.confirmed;
    final exempt = request.isPaymentExempt;
    final downPaymentVerified =
        request.totalAmountCentavos > 0 &&
        request.verifiedAmountCentavos >= request.requiredDownPaymentCentavos;
    final fullyPaid =
        request.totalAmountCentavos > 0 &&
        request.verifiedAmountCentavos >= request.totalAmountCentavos;

    final steps = <Widget>[
      step('Reservation Submitted', true),
      step('Admin Approved', approved),
    ];
    if (exempt) {
      steps.add(step('Payment Not Required', true));
    } else if (request.totalAmountCentavos > 0) {
      steps.add(step('Downpayment Verified', downPaymentVerified));
      if (downPaymentVerified) {
        steps.add(step('Full Payment Verified', fullyPaid));
      }
    }
    steps.add(step('Reservation Confirmed', confirmed));
    return steps;
  }

  Widget _feedbackSection(AppState state, ReservationRequest request) {
    final c = context.srColors;
    // Built as a list of independent blocks, not a chain of early returns:
    // a facility-use assessment and the renter's own review are unrelated
    // facts about the same reservation and can both be present.
    final blocks = <Widget>[];

    if (request.useAssessments.isNotEmpty) {
      final assessment = request.useAssessments.last;
      blocks.add(
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Admin facility-use feedback', style: SrType.label()),
              const SizedBox(height: 5),
              Text(
                'Cleanliness ${assessment.cleanlinessRating}/5 · '
                'Equipment ${assessment.equipmentConditionRating}/5',
                style: sans(12, w: 600, color: c.textSecondary),
              ),
              if (assessment.leftUnclean || assessment.equipmentDamaged)
                Text(
                  [
                    if (assessment.leftUnclean) 'Left unclean',
                    if (assessment.equipmentDamaged) 'Equipment damaged',
                  ].join(' · '),
                  style: sans(12, w: 600, color: c.redInk),
                ),
              if (assessment.comment.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  assessment.comment,
                  style: sans(12, height: 1.4, color: c.textSecondary),
                ),
              ],
              if (assessment.files.isNotEmpty) ...[
                const SizedBox(height: 8),
                EvidenceThumbnailStrip(
                  files: assessment.files,
                  resolveUrl: state.assessmentEvidenceUrl,
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (request.feedbackRating != null) {
      blocks.add(
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: c.surfaceSunken,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SrRatingStars(
                average: request.feedbackRating!.toDouble(),
                count: 1,
                dense: true,
                showCount: false,
              ),
              if (request.feedbackComment.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  request.feedbackComment,
                  style: sans(12, height: 1.4, color: c.textSecondary),
                ),
              ],
            ],
          ),
        ),
      );
      if (request.feedbackReply case final reply?) {
        blocks.add(
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: c.surfaceSunken,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reply from administrator', style: SrType.label()),
                const SizedBox(height: 5),
                Text(
                  '${reply.adminName} · ${_shortDate(reply.updatedAt)}',
                  style: sans(11, w: 600, color: c.textMuted),
                ),
                const SizedBox(height: 4),
                Text(
                  reply.message,
                  style: sans(12, height: 1.4, color: c.textSecondary),
                ),
              ],
            ),
          ),
        );
      }
    } else if (state.canLeaveFeedback(request)) {
      blocks.add(
        SrButton(
          label: 'Rate your visit',
          kind: SrButtonKind.primary,
          dense: true,
          onPressed: () =>
              showFeedbackDialog(context, state: state, request: request),
        ),
      );
    } else if (request.lifecycleStatus ==
        ReservationLifecycleStatus.confirmed) {
      blocks.add(
        Text(
          'Feedback becomes available after your reservation is completed.',
          style: sans(11, color: c.textMuted),
        ),
      );
    }

    if (blocks.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < blocks.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            blocks[i],
          ],
        ],
      ),
    );
  }

  static String _shortDate(DateTime value) =>
      '${value.month}/${value.day}/${value.year}';

  List<Widget> _selfCheckInRows(AppState state, ReservationRequest request) {
    if (request.lifecycleStatus != ReservationLifecycleStatus.confirmed) {
      return const [];
    }
    final rows = <Widget>[];
    for (final occurrence in request.occurrences.where(
      (item) => item.isBooked,
    )) {
      final now = campusNow();
      final checkedIn = occurrence.stage.index >= BookingStage.checkedIn.index;
      final inWindow = occurrence.canCheckInAt(now);
      final lateNow = occurrence.lateMinutesAt(now);
      final busy = state.reservationActionsPending.contains(
        'checkin:${occurrence.id}',
      );
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: context.srColors.surfaceSunken,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${formatCampusDate(occurrence.startsAt)} · '
                  '${_reservationClock(occurrence.startsAt)}',
                  style: mono(10.5, color: context.srColors.ink3),
                ),
                if (checkedIn)
                  SrPill(
                    label: occurrence.checkedInLate
                        ? 'Checked in · ${occurrence.checkInLateMinutes} min late'
                        : 'Checked in',
                    background: occurrence.checkedInLate
                        ? context.srColors.amberTint
                        : context.srColors.greenTint,
                    foreground: occurrence.checkedInLate
                        ? context.srColors.amberTitle
                        : context.srColors.greenDark,
                    fontSize: 10.5,
                  )
                else if (inWindow) ...[
                  SrButton(
                    label: busy ? 'Checking in...' : 'Check in',
                    kind: SrButtonKind.primary,
                    dense: true,
                    onPressed: busy
                        ? null
                        : () =>
                              state.selfCheckInOccurrence(request, occurrence),
                  ),
                  if (lateNow > 0)
                    Text(
                      'You are $lateNow ${lateNow == 1 ? 'minute' : 'minutes'} '
                      'late. This will be recorded.',
                      style: sans(11, color: context.srColors.amberTitle),
                    ),
                ] else
                  Text(
                    now.isBefore(occurrence.checkInOpensAt)
                        ? 'Check-in opens 30 minutes before start.'
                        : 'Check-in closed 30 minutes after start.',
                    style: sans(11, color: context.srColors.muted),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return rows;
  }

  Future<void> _submitPayment(
    AppState state,
    ReservationRequest request, {
    PaymentTransaction? correctingPayment,
  }) async {
    await showPaymentProofSheet(
      context,
      state: state,
      request: request,
      mode: correctingPayment == null
          ? PaymentProofMode.initialSubmission
          : PaymentProofMode.correctionSubmission,
      correctingPayment: correctingPayment,
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
    final campusTodayValue = campusNow();
    final today = DateTime(
      campusTodayValue.year,
      campusTodayValue.month,
      campusTodayValue.day,
    );
    var date = DateTime(
      occurrence.startsAt.year,
      occurrence.startsAt.month,
      occurrence.startsAt.day,
    );
    if (date.isBefore(today)) date = today;
    var startTime = TimeOfDay.fromDateTime(occurrence.startsAt);
    var endTime = TimeOfDay.fromDateTime(occurrence.endsAt);
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
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(alwaysUse24HourFormat: false),
                  child: child!,
                ),
              );
              if (picked != null) {
                setDialogState(() => startTime = picked);
              }
            },
            child: Text(
              'From ${formatClock12(startTime.hour + startTime.minute / 60)}',
            ),
          );
          final toButton = OutlinedButton(
            style: buttonStyle,
            onPressed: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: endTime,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(alwaysUse24HourFormat: false),
                  child: child!,
                ),
              );
              if (picked != null) setDialogState(() => endTime = picked);
            },
            child: Text(
              'To ${formatClock12(endTime.hour + endTime.minute / 60)}',
            ),
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
                Divider(height: 1, color: context.srColors.border),
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
                Divider(height: 1, color: context.srColors.border),
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

  Future<void> _requestReschedule(
    AppState state,
    ReservationRequest request,
    ReservationOccurrence occurrence,
  ) async {
    final reason = TextEditingController();
    final now = campusNow();
    final today = DateTime(now.year, now.month, now.day);
    final facility = state.facilityNamed(request.facility);
    final lastDate = today.add(
      Duration(days: facility?.advanceBookingDays ?? 365),
    );
    var date = DateTime(
      occurrence.startsAt.year,
      occurrence.startsAt.month,
      occurrence.startsAt.day,
    );
    if (date.isBefore(today)) date = today;
    if (date.isAfter(lastDate)) date = lastDate;
    var startTime = TimeOfDay.fromDateTime(occurrence.startsAt);
    var endTime = TimeOfDay.fromDateTime(occurrence.endsAt);
    final duration = occurrence.endsAt.difference(occurrence.startsAt);
    final maxDurationMinutes = facility?.maxDurationMinutes ?? 24 * 60;
    final maxDurationLabel = maxDurationMinutes % 60 == 0
        ? '${maxDurationMinutes ~/ 60} '
              '${maxDurationMinutes == 60 ? 'hour' : 'hours'}'
        : '$maxDurationMinutes minutes';
    String? error;

    DateTime selectedStart() => DateTime.utc(
      date.year,
      date.month,
      date.day,
      startTime.hour,
      startTime.minute,
    );

    DateTime selectedEnd() => DateTime.utc(
      date.year,
      date.month,
      date.day,
      endTime.hour,
      endTime.minute,
    );

    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final compact = SR.isCompact(MediaQuery.sizeOf(context).width);
          final startsAt = selectedStart();
          final endsAt = selectedEnd();
          final selectedDuration = endsAt.difference(startsAt);
          final buttonStyle = OutlinedButton.styleFrom(
            minimumSize: const Size(44, 44),
          );
          return SrAdaptiveDialog(
            maxWidth: 500,
            maxHeight: 570,
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
                          'Request reschedule',
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
                Divider(height: 1, color: context.srColors.border),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(compact ? 16 : 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'The original slot is released after this request is '
                          'sent. The new schedule returns to admin approval.',
                          style: sans(
                            11.5,
                            height: 1.5,
                            color: context.srColors.ink4,
                          ),
                        ),
                        const SizedBox(height: 14),
                        OutlinedButton(
                          style: buttonStyle,
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: date,
                              firstDate: today,
                              lastDate: lastDate,
                            );
                            if (picked != null) {
                              setDialogState(() {
                                date = picked;
                                error = null;
                              });
                            }
                          },
                          child: Text(_reservationDate(date)),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                style: buttonStyle,
                                onPressed: () async {
                                  final picked = await showTimePicker(
                                    context: context,
                                    initialTime: startTime,
                                    builder: (context, child) => MediaQuery(
                                      data: MediaQuery.of(context).copyWith(
                                        alwaysUse24HourFormat: false,
                                      ),
                                      child: child!,
                                    ),
                                  );
                                  if (picked != null) {
                                    setDialogState(() {
                                      startTime = picked;
                                      error = null;
                                    });
                                  }
                                },
                                child: Text(
                                  'Starts ${formatClock12(startTime.hour + startTime.minute / 60)}',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                style: buttonStyle,
                                onPressed: () async {
                                  final picked = await showTimePicker(
                                    context: context,
                                    initialTime: endTime,
                                    builder: (context, child) => MediaQuery(
                                      data: MediaQuery.of(context).copyWith(
                                        alwaysUse24HourFormat: false,
                                      ),
                                      child: child!,
                                    ),
                                  );
                                  if (picked != null) {
                                    setDialogState(() {
                                      endTime = picked;
                                      error = null;
                                    });
                                  }
                                },
                                child: Text(
                                  'Ends ${formatClock12(endTime.hour + endTime.minute / 60)}',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          request.totalAmountCentavos > 0
                              ? 'Maximum $maxDurationLabel. '
                                    'Paid reservations keep the original '
                                    '${duration.inMinutes}-minute duration.'
                              : 'Maximum duration: $maxDurationLabel.',
                          style: sans(10.5, color: context.srColors.muted),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(11),
                          decoration: BoxDecoration(
                            color: context.srColors.surfaceSubtle,
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                              color: context.srColors.hairline,
                            ),
                          ),
                          child: Text(
                            'New schedule · ${_reservationDate(startsAt)} · '
                            '${_reservationClock(startsAt)}–'
                            '${_reservationClock(endsAt)} '
                            '(${selectedDuration.inMinutes} minutes)',
                            style: mono(10.5, color: context.srColors.ink3),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: reason,
                          minLines: 2,
                          maxLines: 4,
                          maxLength: 300,
                          decoration: const InputDecoration(
                            labelText: 'Reason for moving',
                            hintText: 'Briefly explain why you need a new time.',
                          ),
                        ),
                        if (error != null)
                          Text(
                            error!,
                            style: sans(11.5, color: context.srColors.red),
                          ),
                      ],
                    ),
                  ),
                ),
                Divider(height: 1, color: context.srColors.border),
                Padding(
                  padding: EdgeInsets.all(compact ? 16 : 18),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {
                          final candidateStart = selectedStart();
                          final candidateEnd = selectedEnd();
                          final unchanged =
                              candidateStart == occurrence.startsAt &&
                              candidateEnd == occurrence.endsAt;
                          final crossesDay =
                              candidateEnd.year != candidateStart.year ||
                              candidateEnd.month != candidateStart.month ||
                              candidateEnd.day != candidateStart.day;
                          if (!candidateStart.isAfter(campusNow())) {
                            setDialogState(
                              () => error = 'Choose a future start time.',
                            );
                          } else if (!candidateEnd.isAfter(candidateStart)) {
                            setDialogState(
                              () => error =
                                  'Choose an end time later than the start time.',
                            );
                          } else if (unchanged) {
                            setDialogState(
                              () => error = 'Choose a different schedule.',
                            );
                          } else if (crossesDay) {
                            setDialogState(
                              () => error =
                                  'The reservation must end on the same day.',
                            );
                          } else if (candidateEnd.difference(candidateStart) !=
                                  duration &&
                              request.totalAmountCentavos > 0) {
                            setDialogState(
                              () => error =
                                  'Paid reservations must keep the original '
                                  '${duration.inMinutes}-minute duration.',
                            );
                          } else if (candidateEnd
                                  .difference(candidateStart)
                                  .inMinutes >
                              maxDurationMinutes) {
                            setDialogState(
                              () => error =
                                  'The maximum reservation time for this '
                                  'facility is $maxDurationLabel.',
                            );
                          } else if (reason.text.trim().length < 3) {
                            setDialogState(
                              () => error =
                                  'Add a short reason for the administrator.',
                            );
                          } else {
                            Navigator.pop(context, true);
                          }
                        },
                        child: const Text('Send request'),
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
      final startsAt = selectedStart();
      await state.requestReservationReschedule(
        request,
        occurrence,
        startsAt: startsAt,
        endsAt: selectedEnd(),
        reason: reason.text,
      );
    }
    reason.dispose();
  }

  static String _reservationClock(DateTime value) =>
      formatClock12(value.hour + value.minute / 60);

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
    final wide = width >= SR.expandedMin;
    final compact = SR.isCompact(width);
    final hasProfileDetails =
        state.userDetailsEditable ||
        (account.verification != VerificationState.none &&
            (account.idNumber.trim().isNotEmpty ||
                account.unit.trim().isNotEmpty));
    final bookingAndDetails = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _verificationPanel(state, account),
        if (hasProfileDetails) ...[
          const SizedBox(height: SR.space16),
          _profileDetailsPanel(state, account),
        ],
      ],
    );

    final preferences = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.loyaltyAvailableForCurrentUser) ...[
          SrCard.bare(
            child: SrListRow(
              key: const Key('student-loyalty-entry'),
              icon: Icons.stars_rounded,
              label: 'Rewards & points',
              value: '${state.loyalty?.balance ?? 0} pts',
              valueMono: true,
              trailing: const Icon(Icons.chevron_right_rounded, size: 18),
              onTap: () => _openLoyalty(context),
            ),
          ),
          const SizedBox(height: SR.space16),
        ],
        _preferencesPanel(state, compact),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _accountOverview(account, compact),
        const SizedBox(height: SR.space16),
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
        const SizedBox(height: SR.space16),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 7, child: bookingAndDetails),
              const SizedBox(width: SR.space16),
              Expanded(flex: 5, child: preferences),
            ],
          )
        else ...[
          bookingAndDetails,
          const SizedBox(height: SR.space16),
          preferences,
        ],
        const SizedBox(height: SR.space16),
        _accountActions(state),
      ],
    );
  }

  Widget _accountOverview(Account account, bool compact) => SrCard(
    key: const Key('student-account-overview'),
    padding: EdgeInsets.all(compact ? SR.space16 : SR.space20),
    child: compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _accountIdentity(account),
              const SizedBox(height: SR.space12),
              Align(
                alignment: Alignment.centerLeft,
                child: _verificationPill(account),
              ),
            ],
          )
        : Row(
            children: [
              Expanded(child: _accountIdentity(account)),
              const SizedBox(width: SR.space16),
              _verificationPill(account),
            ],
          ),
  );

  Widget _accountIdentity(Account account) => Row(
    children: [
      SrAvatar(initials: account.initials, size: 52),
      const SizedBox(width: SR.space12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              account.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SrType.heading(),
            ),
            const SizedBox(height: SR.space2),
            Text(
              account.email,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SrType.code(color: context.srColors.muted),
            ),
            const SizedBox(height: SR.space4),
            Text(account.roleLabel, style: SrType.caption()),
            const SizedBox(height: SR.space2),
            Text('Joined ${account.joined}', style: SrType.caption()),
          ],
        ),
      ),
    ],
  );

  Widget _verificationPill(Account account) => SrPill(
    label: account.verification.label,
    background: account.verification.background,
    foreground: account.verification.foreground,
  );

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
        context.srColors.greenTint,
        context.srColors.greenLine,
        context.srColors.greenDark,
        'Verified campus member',
        'New requests use the internal-admin lane and this facility’s '
            'published campus-member rate. Verification runs to the end of '
            'the academic year.',
        null,
      ),
      VerificationState.pending => (
        context.srColors.amberTint,
        context.srColors.amberLine,
        context.srColors.amber,
        'Awaiting review',
        'Documents are reviewed each morning, usually within one business '
            'day. Requests submitted now use the external-admin lane; later '
            'verification does not transfer an existing case.',
        null,
      ),
      VerificationState.rejected => (
        context.srColors.redTint,
        context.srColors.redLine,
        context.srColors.red,
        'Campus claim not approved',
        'You can still reserve through the external/unverified lane at each '
            'facility’s renter rate. One appeal with a different document is '
            'allowed.',
        'Appeal with another document',
      ),
      VerificationState.none => (
        context.srColors.primaryTint2,
        context.srColors.primaryLine,
        SR.primaryHover,
        'Booking as a renter',
        'Campus members may have a different facility rate. If that is you, '
            'verification takes about a minute.',
        'I am a campus member',
      ),
    };

    return Container(
      padding: const EdgeInsets.all(SR.space20),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(SR.rLg),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('BOOKING ACCESS', style: keyLabel),
          const SizedBox(height: SR.space8),
          Text(title, style: sans(13.5, w: 600, tracking: -.01, color: accent)),
          const SizedBox(height: 6),
          Text(
            body,
            style: sans(12, height: 1.65, color: context.srColors.ink4),
          ),
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

  Widget _profileDetailsPanel(AppState state, Account account) => SrCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Profile details', style: SrType.subhead()),
        const SizedBox(height: SR.space2),
        Text(
          state.userDetailsEditable
              ? 'Update the details stored with this account.'
              : 'Campus information is provided by your account and verification record.',
          style: SrType.caption(),
        ),
        const SizedBox(height: SR.space16),
        _detailsGrid(state, account),
      ],
    ),
  );

  Widget _detailsGrid(AppState state, Account account) {
    final locked = !state.userDetailsEditable;
    final tiles = <Widget>[
      if (!locked)
        _detailTile(
          state,
          label: 'FULL NAME',
          field: 'name',
          value: account.name,
          locked: false,
        ),
      if (!locked ||
          (account.verification != VerificationState.none &&
              account.idNumber.trim().isNotEmpty))
        _detailTile(
          state,
          label: 'ID NUMBER',
          field: 'idNumber',
          value: account.idNumber,
          locked: locked,
          valueMono: true,
        ),
      if (!locked ||
          (account.verification != VerificationState.none &&
              account.unit.trim().isNotEmpty))
        _detailTile(
          state,
          label: 'PROGRAMME / UNIT',
          field: 'unit',
          value: account.unit,
          locked: locked,
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 520 ? 2 : 1;
        final tileWidth =
            (constraints.maxWidth - (columns - 1) * SR.space12) / columns;
        return Wrap(
          spacing: SR.space12,
          runSpacing: SR.space12,
          children: [
            for (final tile in tiles) SizedBox(width: tileWidth, child: tile),
          ],
        );
      },
    );
  }

  Widget _detailTile(
    AppState state, {
    required String label,
    required String field,
    required String value,
    required bool locked,
    bool valueMono = false,
  }) {
    final editing = _editingField == field;
    return Container(
      constraints: const BoxConstraints(minHeight: 108),
      padding: const EdgeInsets.all(SR.space12),
      decoration: BoxDecoration(
        color: context.srColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(SR.rMd),
        border: Border.all(color: context.srColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: keyLabel),
          const SizedBox(height: SR.space8),
          if (editing) ...[
            SrTextField(
              controller: _editController,
              semanticLabel: label,
              mono: valueMono,
              fontSize: 12.5,
              autofocus: true,
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              onSubmitted: (_) => _saveDetail(state, field),
            ),
            const SizedBox(height: SR.space8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SrButton(
                  label: 'Cancel',
                  dense: true,
                  fontSize: 11,
                  onPressed: () => setState(() => _editingField = null),
                ),
                const SizedBox(width: SR.space6),
                SrButton(
                  label: 'Save',
                  kind: SrButtonKind.primary,
                  dense: true,
                  fontSize: 11,
                  onPressed: () => _saveDetail(state, field),
                ),
              ],
            ),
          ] else ...[
            Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: valueMono ? mono(12.5, w: 500) : sans(12.5, w: 500),
            ),
            if (!locked) ...[
              const SizedBox(height: SR.space8),
              Align(
                alignment: Alignment.centerRight,
                child: SrButton(
                  label: 'Edit',
                  dense: true,
                  fontSize: 11,
                  onPressed: () {
                    _editController.text = value;
                    setState(() => _editingField = field);
                  },
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _preferencesPanel(AppState state, bool compact) => SrCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SrSectionHeader(
          title: 'Preferences',
          description: 'Control notifications and how SmartReserve looks.',
          icon: Icons.tune_rounded,
        ),
        Text('Notifications', style: SrType.label()),
        const SizedBox(height: SR.space8),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: context.srColors.border),
            borderRadius: BorderRadius.circular(SR.rMd),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (
                var index = 0;
                index < state.notificationPreferences.entries.length;
                index++
              ) ...[
                SrListRow(
                  label: state.notificationPreferences.entries
                      .elementAt(index)
                      .key,
                  trailing: SrToggle(
                    value: state.notificationPreferences.entries
                        .elementAt(index)
                        .value,
                    label: state.notificationPreferences.entries
                        .elementAt(index)
                        .key,
                    onChanged: (value) => state.setNotificationPreference(
                      state.notificationPreferences.entries
                          .elementAt(index)
                          .key,
                      value,
                    ),
                  ),
                ),
                Divider(height: 1, color: context.srColors.border),
              ],
              _pushRow(state),
            ],
          ),
        ),
        const SizedBox(height: SR.space16),
        Divider(height: 1, color: context.srColors.border),
        const SizedBox(height: SR.space16),
        Text('Appearance', style: SrType.label()),
        const SizedBox(height: SR.space4),
        Text(
          'Follow this device or choose a theme for SmartReserve.',
          style: SrType.caption(),
        ),
        const SizedBox(height: SR.space12),
        SrThemeSelector(
          value: state.themePreference,
          compact: compact,
          onChanged: state.setThemePreference,
        ),
      ],
    ),
  );

  Widget _pushRow(AppState state) {
    final push = state.pushService;
    if (push == null || !push.isSupported) {
      return const SrListRow(
        label: 'Enable push on this device',
        value: 'Not supported here',
      );
    }
    if (push.isRegistered) {
      return const SrListRow(
        label: 'Push notifications',
        value: 'Active on this device',
      );
    }
    return SrListRow(
      label: 'Enable push on this device',
      trailing: SrButton(
        label: _pushBusy ? 'Requesting…' : 'Enable',
        dense: true,
        fontSize: 11,
        onPressed: _pushBusy
            ? null
            : () async {
                setState(() => _pushBusy = true);
                final granted = await state.enablePushNotifications();
                if (!mounted) return;
                setState(() => _pushBusy = false);
                if (!granted) {
                  state.showToast(
                    const ToastMessage(
                      'Push notifications were not enabled. Check your browser or device permission settings.',
                      tone: AdvisoryTone.block,
                    ),
                  );
                }
              },
      ),
    );
  }

  Widget _accountActions(AppState state) => SrCard(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final stack = constraints.maxWidth < 440;
        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Account actions', style: SrType.subhead()),
            const SizedBox(height: SR.space2),
            Text('End this session on this device.', style: SrType.caption()),
          ],
        );
        final action = SrButton(
          label: 'Sign out',
          kind: SrButtonKind.danger,
          expand: stack,
          minHeight: SR.controlMd,
          fontSize: 12.5,
          onPressed: () => state.signOut(),
        );
        return stack
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  heading,
                  const SizedBox(height: SR.space12),
                  action,
                ],
              )
            : Row(
                children: [
                  Expanded(child: heading),
                  const SizedBox(width: SR.space16),
                  action,
                ],
              );
      },
    ),
  );

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
    StudentTab.calendar,
    StudentTab.mine,
    StudentTab.account,
  ];

  @override
  Widget build(BuildContext context) {
    final index = _pillTabs.indexOf(selected);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Container(
                height: 60,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: context.srColors.surface,
                  borderRadius: BorderRadius.circular(SR.rFull),
                  border: Border.all(color: context.srColors.border),
                  boxShadow: SR.floatShadow,
                ),
                child: Stack(
                  children: [
                    AnimatedAlign(
                      duration: SR.stateChange,
                      curve: SR.easing,
                      alignment: Alignment(
                        -1 + index * (2 / (_pillTabs.length - 1)),
                        0,
                      ),
                      child: FractionallySizedBox(
                        widthFactor: 1 / _pillTabs.length,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: SR.space6,
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: context.srColors.primaryTint,
                              borderRadius: BorderRadius.circular(SR.rFull),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Row(
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
}

class _AssistantButton extends StatelessWidget {
  const _AssistantButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.srColors;
    return Semantics(
      button: true,
      label: 'Assistant',
      child: Hoverable(
        builder: (context, hovered) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: SR.stateChange,
            width: 58,
            height: 60,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.isDark ? colors.surfaceElevated : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: hovered ? colors.brand : colors.border),
              boxShadow: hovered ? SR.popoverShadow : SR.floatShadow,
            ),
            child: const SrAssistantLogo(
              size: 42,
              radius: 21,
              padding: 4,
              backgroundColor: Colors.transparent,
              borderColor: Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatefulWidget {
  const _BottomNavItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final StudentTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_BottomNavItem> createState() => _BottomNavItemState();
}

class _BottomNavItemState extends State<_BottomNavItem> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.selected
        ? context.srColors.primaryDeep
        : context.srColors.ink4;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.tab.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        child: AnimatedScale(
          scale: _pressed ? .92 : 1,
          duration: SR.stateChange,
          curve: SR.easing,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.selected ? widget.tab.selectedIcon : widget.tab.icon,
                size: 21,
                color: color,
              ),
              const SizedBox(height: 3),
              Text(
                widget.tab.short,
                style: SrType.caption(
                  w: widget.selected ? 700 : 600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryShortcut extends StatelessWidget {
  const _CategoryShortcut({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 9),
    child: Semantics(
      button: true,
      selected: selected,
      label: 'Show $label facilities',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SR.rLg),
        child: AnimatedContainer(
          duration: SR.stateChange,
          width: 92,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? context.srColors.primaryTint
                : context.srColors.surface,
            borderRadius: BorderRadius.circular(SR.rLg),
            border: Border.all(
              color: selected
                  ? context.srColors.primaryLine
                  : context.srColors.border,
            ),
            boxShadow: selected ? null : SR.cardShadow,
          ),
          child: Column(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? SR.primary : context.srColors.surfaceSubtle,
                  borderRadius: BorderRadius.circular(SR.rMd),
                ),
                child: Icon(
                  icon,
                  size: 19,
                  color: selected ? Colors.white : SR.primary,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sans(
                  10.5,
                  w: selected ? 600 : 500,
                  color: selected
                      ? context.srColors.primaryDeep
                      : context.srColors.ink3,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
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
    color: context.srColors.surface,
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
                color: selected.contains(amenity)
                    ? SR.primary
                    : context.srColors.muted,
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
          color: selected.isEmpty
              ? context.srColors.surface
              : context.srColors.primaryTint,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected.isEmpty
                ? context.srColors.border
                : context.srColors.primarySoft,
          ),
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
                style: sans(11.5, w: 500, color: context.srColors.ink3),
              ),
            ),
            const SizedBox(width: 7),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: context.srColors.muted,
            ),
          ],
        ),
      ),
    ),
  );
}

enum _BrowseStatusKind { loading, error, empty, noMatch }

class _BrowseStatus extends StatelessWidget {
  const _BrowseStatus.loading()
    : kind = _BrowseStatusKind.loading,
      message = null,
      onAction = null;

  const _BrowseStatus.error({required this.message, required this.onAction})
    : kind = _BrowseStatusKind.error;

  const _BrowseStatus.empty()
    : kind = _BrowseStatusKind.empty,
      message = null,
      onAction = null;

  const _BrowseStatus.noMatch({required this.onAction})
    : kind = _BrowseStatusKind.noMatch,
      message = null;

  final _BrowseStatusKind kind;
  final String? message;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 44),
    decoration: BoxDecoration(
      color: context.srColors.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.srColors.border),
    ),
    child: Column(
      children: [
        if (kind == _BrowseStatusKind.loading)
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: CircularProgressIndicator(strokeWidth: 2.5),
          )
        else
          Icon(
            switch (kind) {
              _BrowseStatusKind.error => Icons.cloud_off_rounded,
              _BrowseStatusKind.empty => Icons.apartment_rounded,
              _BrowseStatusKind.noMatch => Icons.search_off_rounded,
              _BrowseStatusKind.loading => Icons.apartment_rounded,
            },
            color: context.srColors.muted,
            size: 28,
          ),
        const SizedBox(height: 8),
        Text(switch (kind) {
          _BrowseStatusKind.loading => 'Loading facilities',
          _BrowseStatusKind.error => 'Facilities could not be loaded',
          _BrowseStatusKind.empty => 'No public facilities yet',
          _BrowseStatusKind.noMatch => 'No facilities match',
        }, style: sans(14, w: 600)),
        const SizedBox(height: 5),
        Text(
          message ??
              switch (kind) {
                _BrowseStatusKind.loading =>
                  'The latest facility catalogue is being prepared.',
                _BrowseStatusKind.error =>
                  'Check your connection and try loading the catalogue again.',
                _BrowseStatusKind.empty =>
                  'There are no public, non-draft facility listings to show.',
                _BrowseStatusKind.noMatch =>
                  'Try a different search, capacity, category, or amenity.',
              },
          textAlign: TextAlign.center,
          style: sans(12, height: 1.6, color: context.srColors.ink4),
        ),
        if (onAction != null) ...[
          const SizedBox(height: 14),
          SrButton(
            label: kind == _BrowseStatusKind.error
                ? 'Try again'
                : 'Clear filters',
            onPressed: onAction,
          ),
        ],
      ],
    ),
  );
}

class _BrowseRefreshWarning extends StatelessWidget {
  const _BrowseRefreshWarning({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: context.srColors.amberTint,
      borderRadius: BorderRadius.circular(SR.rMd),
      border: Border.all(color: context.srColors.amberLine),
    ),
    child: Row(
      children: [
        Icon(
          Icons.sync_problem_rounded,
          size: 18,
          color: context.srColors.amberTitle,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '$message Showing the most recently loaded facilities.',
            style: sans(11.5, color: context.srColors.amberTitle),
          ),
        ),
        const SizedBox(width: 8),
        SrButton(label: 'Retry', dense: true, onPressed: onRetry),
      ],
    ),
  );
}

String _facilityAvailabilityLabelFor(Facility facility) =>
    switch (facility.state) {
      FacilityState.maintenance => 'Unavailable · maintenance',
      FacilityState.underReview => 'Unavailable · under review',
      FacilityState.draft => 'Unavailable · draft',
      FacilityState.active =>
        facility.bookableForCurrentUser
            ? (facility.approvalRequired
                  ? 'Approval required'
                  : 'Books instantly')
            : switch (facility.bookingBlockReason) {
                FacilityBookingBlockReason.noActiveInternalAdmin =>
                  'Unavailable · no active internal administrator',
                FacilityBookingBlockReason.noActiveExternalAdmin =>
                  'Unavailable · no active external administrator',
                FacilityBookingBlockReason.notAvailableForAccountType =>
                  'Unavailable · not available for your account type',
                _ => 'Unavailable · no administrator',
              },
    };

/// The consistent explanation shown wherever a facility is unbookable
/// specifically because its requester lane has no active administrator
/// (as opposed to maintenance, classification mismatch, or draft status).
String? _facilityAdminUnavailabilityExplanationFor(Facility facility) =>
    switch (facility.bookingBlockReason) {
      FacilityBookingBlockReason.noActiveInternalAdmin ||
      FacilityBookingBlockReason.noActiveExternalAdmin =>
        'Reservations are temporarily unavailable because no active '
            'administrator is available for your account type. Contact '
            'support.',
      _ => null,
    };

SrTone _facilityAvailabilityToneFor(Facility facility) {
  if (facility.state != FacilityState.active ||
      !facility.bookableForCurrentUser) {
    return SrTone.neutral;
  }
  return facility.approvalRequired ? SrTone.warning : SrTone.success;
}

FacilityCatalogueCardData _cardDataFromFacility(
  Facility facility,
  String audience,
) {
  final hourlyRate = facility.hourlyRateCentavosFor(audience);
  return FacilityCatalogueCardData(
    id: facility.id,
    name: facility.name,
    category: facility.category,
    statusLabel: facility.state.label,
    statusTone: facility.state.tone,
    locationLabel: facility.whereLine,
    description: facility.description,
    includedAmenities: List.unmodifiable(facility.amenities),
    capacityLabel: '${facility.capacity} seats',
    hoursLabel: '${facility.hoursLabel} · ${facility.days}',
    approvalLabel: facility.approvalRequired ? 'Required' : 'Instant',
    availabilityLabel: _facilityAvailabilityLabelFor(facility),
    availabilityTone: _facilityAvailabilityToneFor(facility),
    rateLabel: hourlyRate == 0
        ? 'Included rate'
        : '${pesoFromCentavos(hourlyRate * 2)} / 2 h',
    coverPhoto: facility.coverPhoto,
    placeholderHue: facility.thumbHue,
    placeholderIcon: facility.categoryIcon,
    ratingAverage: facility.ratingAverage,
    ratingCount: facility.ratingCount,
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
        Text(
          body,
          style: sans(11.5, height: 1.6, color: context.srColors.ink4),
        ),
      ],
    ),
  );
}
