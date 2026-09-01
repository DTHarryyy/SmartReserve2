import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../app/app_view.dart';
import '../../backend/supabase_service.dart';
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
import '../../widgets/decision_widgets.dart';
import '../../widgets/facility_catalogue_card.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/rating_display.dart';
import '../../widgets/responsive_dialog.dart';
import '../../widgets/sr_assistant_logo.dart';
import '../../widgets/sr_components.dart';
import '../../widgets/sr_controls.dart';
import '../../widgets/sr_scroll_view.dart';
import '../assistant/assistant_chat_page.dart';
import '../assistant/assistant_controller.dart';
import '../calendar/calendar_screen.dart';
import 'booking_sheet.dart';
import 'facility_preview.dart';
import 'feedback_dialog.dart';
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
    'Mine',
    Icons.event_note_outlined,
    Icons.event_note_rounded,
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
    final state = AppScope.of(context);
    if (state.pendingLoyaltyOpen) {
      state.pendingLoyaltyOpen = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(state.refreshLoyalty());
        _openLoyalty(context);
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

  Widget _scrollable(Widget child, double width, bool narrow, {Key? key}) =>
      SrScrollView(
        key: key,
        padding: SR.pageInsets(width, top: narrow ? 14 : 20),
        child: Align(
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
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1A73E8), Color(0xFF00A8EF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
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
                            Text(
                              'Hello, ',
                              style: sans(
                                narrow ? 18 : 21,
                                w: 600,
                                tracking: -.02,
                                color: Colors.white,
                              ),
                            ),
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
                            Text(
                              '! 👋',
                              style: sans(
                                narrow ? 18 : 21,
                                w: 600,
                                tracking: -.02,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      const SizedBox(height: 2),
                      Text(
                        account.email,
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
                    VerificationState.none => 'GUEST',
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
                      onReserve: () => showBookingSheet(
                        context,
                        state: state,
                        facility: facility,
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
            const SizedBox(width: 8),
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
              color: context.srColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.srColors.border),
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
                        if (request.outstandingAmountCentavos > 0 &&
                            !request.paymentTransactions.any(
                              (payment) =>
                                  payment.status ==
                                  PaymentDecisionStatus.submitted,
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
                                : 'Submit GCash proof',
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
                if (state.canCancelReservation(request)) ...[
                  const SizedBox(height: 9),
                  SrButton(
                    label: state.reservationActionsPending.contains(request.id)
                        ? 'Cancelling…'
                        : request.occurrences.length > 1
                        ? 'Cancel all future dates'
                        : 'Cancel reservation',
                    kind: SrButtonKind.danger,
                    dense: true,
                    onPressed:
                        state.reservationActionsPending.contains(request.id)
                        ? null
                        : () async {
                            await state.cancelReservation(request);
                          },
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
    if (request.feedbackRating != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Container(
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
    }
    if (state.canLeaveFeedback(request)) {
      return Padding(
        padding: const EdgeInsets.only(top: 9),
        child: SrButton(
          label: 'Rate your visit',
          kind: SrButtonKind.primary,
          dense: true,
          onPressed: () =>
              showFeedbackDialog(context, state: state, request: request),
        ),
      );
    }
    if (request.lifecycleStatus == ReservationLifecycleStatus.confirmed) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'Feedback becomes available after your reservation is completed.',
          style: sans(11, color: c.textMuted),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Future<void> _submitPayment(
    AppState state,
    ReservationRequest request,
  ) async {
    Facility? facility;
    for (final item in state.facilities) {
      if (item.id == request.facilityId) {
        facility = item;
        break;
      }
    }
    FacilityPaymentMethod? method = request.paymentMethod;
    if (method == null) {
      for (final item
          in facility?.paymentMethods ?? const <FacilityPaymentMethod>[]) {
        if (item.enabled) {
          method = item;
          break;
        }
      }
    }
    if (method == null) {
      state.showToast(
        const ToastMessage(
          'This facility has not published a GCash account yet. '
          'Contact the administrator before sending payment.',
          tone: AdvisoryTone.block,
        ),
      );
      return;
    }

    final depositRemaining =
        request.requiredDownPaymentCentavos - request.verifiedAmountCentavos;
    final fullPaymentDue =
        request.balanceDueAt != null &&
        !request.balanceDueAt!.isAfter(DateTime.now());
    final amount =
        request.lifecycleStatus == ReservationLifecycleStatus.awaitingPayment &&
            !fullPaymentDue
        ? (depositRemaining < 1
              ? 1
              : depositRemaining > request.outstandingAmountCentavos
              ? request.outstandingAmountCentavos
              : depositRemaining)
        : request.outstandingAmountCentavos;
    final amountController = TextEditingController(
      text: (amount / 100).toStringAsFixed(2),
    );
    final referenceController = TextEditingController();
    ReservationUpload? proof;
    String? localError;

    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Submit GCash proof'),
          content: SizedBox(
            width: 430,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (method != null) ...[
                  Text(
                    '${method.accountName} · ${method.accountNumber}',
                    style: sans(13, w: 600),
                  ),
                  if (method.instructions.isNotEmpty)
                    Text(
                      method.instructions,
                      style: sans(
                        11,
                        height: 1.5,
                        color: context.srColors.muted,
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Amount (PHP)'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: referenceController,
                  decoration: const InputDecoration(
                    labelText: 'GCash reference number',
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final file = await FilePicker.pickFile(
                      type: FileType.custom,
                      allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
                    );
                    if (file == null) return;
                    final bytes = await file.readAsBytes();
                    if (bytes.isEmpty ||
                        bytes.lengthInBytes > 10 * 1024 * 1024) {
                      setDialogState(
                        () => localError = 'Proof must be at most 10 MB.',
                      );
                      return;
                    }
                    final extension = file.name.split('.').last.toLowerCase();
                    final mime = switch (extension) {
                      'jpg' || 'jpeg' => 'image/jpeg',
                      'png' => 'image/png',
                      'pdf' => 'application/pdf',
                      _ => '',
                    };
                    if (mime.isEmpty) {
                      setDialogState(
                        () => localError = 'Use a JPG, PNG, or PDF receipt.',
                      );
                      return;
                    }
                    setDialogState(() {
                      proof = ReservationUpload(
                        name: file.name,
                        mimeType: mime,
                        bytes: bytes,
                      );
                      localError = null;
                    });
                  },
                  icon: const Icon(Icons.attach_file_rounded),
                  label: Text(proof?.name ?? 'Choose receipt or screenshot'),
                ),
                if (localError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    localError!,
                    style: sans(11, color: context.srColors.red),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final pesos = double.tryParse(amountController.text.trim());
                if (pesos == null ||
                    pesos <= 0 ||
                    proof == null ||
                    referenceController.text.trim().length < 6) {
                  setDialogState(() {
                    localError = 'Enter a valid amount, reference, and proof.';
                  });
                  return;
                }
                Navigator.pop(context, true);
              },
              child: const Text('Submit proof'),
            ),
          ],
        ),
      ),
    );
    try {
      if (submitted == true && proof != null) {
        final amountCentavos =
            (double.parse(amountController.text.trim()) * 100).round();
        await state.submitReservationPayment(
          request: request,
          purpose:
              request.lifecycleStatus ==
                  ReservationLifecycleStatus.awaitingPayment
              ? PaymentPurpose.downPayment
              : PaymentPurpose.balance,
          amountCentavos: amountCentavos,
          referenceNumber: referenceController.text,
          proof: proof!,
        );
      }
    } finally {
      amountController.dispose();
      referenceController.dispose();
    }
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
                                style: mono(11, color: context.srColors.muted),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Joined ${account.joined}',
                                style: mono(
                                  10.5,
                                  color: context.srColors.muted,
                                ),
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
                            style: mono(11, color: context.srColors.muted),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Joined ${account.joined}',
                            style: mono(10.5, color: context.srColors.muted),
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
                style: sans(11, color: context.srColors.muted),
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
        if (state.loyaltyAvailableForCurrentUser) ...[
          _Panel(
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
          const SizedBox(height: 12),
        ],
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
              Text('Appearance', style: sans(12.5, w: 600)),
              const SizedBox(height: 4),
              Text(
                'Follow this device or choose a theme for SmartReserve.',
                style: sans(11, color: context.srColors.muted),
              ),
              const SizedBox(height: 12),
              SrThemeSelector(
                value: state.themePreference,
                compact: compact,
                onChanged: state.setThemePreference,
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
        'You can still reserve through the guest/unverified lane at each '
            'facility’s guest rate. One appeal with a different document is '
            'allowed.',
        'Appeal with another document',
      ),
      VerificationState.none => (
        context.srColors.primaryTint2,
        context.srColors.primaryLine,
        SR.primaryHover,
        'Booking as a guest',
        'Campus members may have a different facility rate. If that is you, '
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
        color: context.srColors.hairline,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.srColors.hairline),
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
      color: context.srColors.surface,
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
                        Text(
                          lockedNote,
                          style: sans(10.5, color: context.srColors.muted),
                        ),
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
                height: 58,
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
            height: 58,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.isDark ? colors.surfaceElevated : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(
                color: hovered ? colors.brand : colors.border,
              ),
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
      FacilityState.active => facility.bookableForCurrentUser
          ? (facility.approvalRequired ? 'Approval required' : 'Books instantly')
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
    hoursLabel: '${facility.hours} · ${facility.days}',
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

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.background, this.border});

  final Widget child;
  final Color? background;
  final Color? border;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    decoration: BoxDecoration(
      color: background ?? context.srColors.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: border ?? context.srColors.border),
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
        Text(
          body,
          style: sans(11.5, height: 1.6, color: context.srColors.ink4),
        ),
      ],
    ),
  );
}
