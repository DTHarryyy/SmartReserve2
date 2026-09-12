import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backend/supabase_service.dart';
import '../data/campus_data.dart';
import '../data/seed_accounts.dart';
import '../data/seed_audit.dart';
import '../data/seed_facilities.dart';
import '../data/seed_loyalty.dart';
import '../data/seed_reservations.dart';
import '../model/account.dart';
import '../model/amenity_request.dart';
import '../model/anomaly.dart';
import '../model/audit_diff.dart';
import '../model/audit_entry.dart';
import '../model/calendar_event.dart';
import '../model/facility.dart';
import '../model/facility_draft.dart';
import '../model/feedback.dart';
import '../model/loyalty.dart';
import '../model/notice.dart';
import '../model/payment.dart';
import '../model/permit.dart';
import '../model/reservation.dart';
import '../model/verification.dart';
import '../features/assistant/assistant_availability.dart';
import '../features/reports/reports_data.dart';
import '../features/reservations/conflict_engine.dart';
import '../util/backend_errors.dart';
import '../util/campus_calendar.dart';
import '../util/geo.dart';
import '../theme/sr_theme.dart';
import '../features/reports/report_scope_url.dart';
import 'app_view.dart';
import 'sr_toast_controller.dart';

class AdministratorCredentials {
  const AdministratorCredentials({
    required this.email,
    required this.temporaryPassword,
  });

  final String email;
  final String temporaryPassword;

  String get exportText =>
      'SmartReserve administrator credentials\n\n'
      'Email: $email\n'
      'Temporary password: $temporaryPassword\n\n'
      'Store this file securely. Change the temporary password after the '
      'first sign-in.';
}

class AdministratorCreationResult {
  const AdministratorCreationResult._({this.credentials, this.error});

  const AdministratorCreationResult.success(AdministratorCredentials value)
    : this._(credentials: value);

  const AdministratorCreationResult.failure(String value)
    : this._(error: value);

  final AdministratorCredentials? credentials;
  final String? error;
}

class AccountCredentials {
  const AccountCredentials({
    required this.email,
    required this.temporaryPassword,
    required this.title,
    this.fullName,
    this.organization,
  });

  final String email;
  final String temporaryPassword;
  final String title;
  final String? fullName;
  final String? organization;

  String get exportText =>
      'SmartReserve $title credentials\n\n'
      '${fullName == null || fullName!.isEmpty ? '' : 'Name: $fullName\n'}'
      '${organization == null || organization!.isEmpty ? '' : 'Organization: $organization\n'}'
      'Email: $email\n'
      'Temporary password: $temporaryPassword\n\n'
      'Store this file securely. The account holder must change the temporary '
      'password after first sign-in.';
}

class AccountCreationResult {
  const AccountCreationResult._({this.credentials, this.error});

  const AccountCreationResult.success(AccountCredentials value)
    : this._(credentials: value);

  const AccountCreationResult.failure(String value) : this._(error: value);

  final AccountCredentials? credentials;
  final String? error;
}

enum AvailabilitySource { live, demo, localFallback }

class AvailabilitySnapshot {
  const AvailabilitySnapshot({
    required this.windows,
    required this.source,
    required this.fetchedAt,
  });

  final Map<String, List<BusyWindow>> windows;
  final AvailabilitySource source;
  final DateTime fetchedAt;

  bool get isTrusted =>
      source == AvailabilitySource.live || source == AvailabilitySource.demo;
}

class ReportFailure {
  const ReportFailure({
    required this.explanation,
    required this.supportReference,
  });

  final String explanation;
  final String supportReference;
}

sealed class ReportLoadState {
  const ReportLoadState();

  ReportSnapshot? get snapshot => switch (this) {
    ReportReady(:final snapshot) ||
    ReportRefreshing(:final snapshot) ||
    ReportStale(:final snapshot) => snapshot,
    _ => null,
  };

  ReportFailure? get failure => switch (this) {
    ReportStale(:final failure) || ReportFailed(:final failure) => failure,
    _ => null,
  };

  bool get isLoading =>
      this is ReportInitialLoading || this is ReportRefreshing;
  bool get isRefreshing => this is ReportRefreshing;
  bool get isStale => this is ReportStale;
  bool get hasVerifiedSnapshot => snapshot != null;
}

class ReportInitialLoading extends ReportLoadState {
  const ReportInitialLoading();
}

class ReportReady extends ReportLoadState {
  const ReportReady(this.snapshot);

  @override
  final ReportSnapshot snapshot;
}

class ReportRefreshing extends ReportLoadState {
  const ReportRefreshing(this.snapshot);

  @override
  final ReportSnapshot snapshot;
}

class ReportStale extends ReportLoadState {
  const ReportStale(this.snapshot, this.failure);

  @override
  final ReportSnapshot snapshot;
  @override
  final ReportFailure failure;
}

class ReportFailed extends ReportLoadState {
  const ReportFailed(this.failure);

  @override
  final ReportFailure failure;
}

class AppState extends ChangeNotifier {
  AppState({bool useDemoData = true}) : _useDemoData = useDemoData {
    facilities = useDemoData ? seedFacilities() : [];
    requests = useDemoData ? seedRequests() : [];
    bookings = useDemoData ? [...seedBookings(), ...seriesDemoBookings()] : [];
    verifications = useDemoData ? seedVerifications() : [];
    accounts = useDemoData ? seedAccounts() : [];
    organizationUnits = [];
    organizationSlots = [];
    audit = useDemoData ? seedAudit() : [];
    calendarAnchor = useDemoData ? campusToday : campusNow();
    userCalendarAnchor = calendarAnchor;
  }

  final bool _useDemoData;
  bool get usesDemoData => _useDemoData;

  final SrToastController toasts = SrToastController();

  static const _themePreferenceKey = 'sr.theme_mode.v1';

  SrThemePreference themePreference = SrThemePreference.system;

  Future<void> loadThemePreference() async {
    final preferences = await SharedPreferences.getInstance();
    themePreference = SrThemePreference.fromStorage(
      preferences.getString(_themePreferenceKey),
    );
    notifyListeners();
  }

  Future<void> setThemePreference(SrThemePreference preference) async {
    if (themePreference == preference) return;
    themePreference = preference;
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_themePreferenceKey, preference.name);
  }

  AppView view = AppView.auth;

  AppView _profileOrigin = AppView.auth;

  void goTo(AppView next) {
    if (next == AppView.organizations && !isInternalAdmin) {
      showToast(
        const ToastMessage(
          'Organization management is restricted to Internal Admins.',
          tone: AdvisoryTone.block,
        ),
      );
      return;
    }
    if (isExternalAdmin &&
        (next == AppView.verifications || next == AppView.audit)) {
      showToast(
        const ToastMessage(
          'This administrator role cannot access that area.',
          tone: AdvisoryTone.block,
        ),
      );
      return;
    }
    if (next == AppView.loyalty && !isExternalAdmin) {
      _clearAdminLoyaltyState();
      showToast(
        const ToastMessage(
          'This administrator role cannot access that area.',
          tone: AdvisoryTone.block,
        ),
      );
      notifyListeners();
      return;
    }
    if (hasSession && !isAdmin && next.usesAdminChrome) {
      showToast(
        const ToastMessage(
          'This account cannot access the admin console.',
          tone: AdvisoryTone.block,
        ),
      );
      return;
    }
    if (next == AppView.profile) _profileOrigin = view;
    if (view == next) return;
    view = next;
    if (next == AppView.reports) unawaited(refreshReports());
    if (next == AppView.audit) unawaited(refreshAudit());
    if (next == AppView.feedback) unawaited(refreshFeedback());
    if (next == AppView.loyalty) {
      unawaited(refreshExternalLoyaltyAdmin());
    }
    if (next == AppView.anomalies) unawaited(refreshAnomalyCenter());
    closeOverlays();
    notifyListeners();
  }

  Future<void> refreshReports({ReportScope? scope}) async {
    final service = backend;
    if (_useDemoData || service == null || !isAdmin) return;
    final requested = scope ?? ReportScope.forRange(ReportRange.month);
    final requestId = ++_reportRequestId;
    final prior = reportState.snapshot;
    final canKeepPrior = prior?.hasSameSelection(requested) ?? false;
    reportScope = requested;
    reportState = canKeepPrior
        ? ReportRefreshing(prior!)
        : const ReportInitialLoading();
    notifyListeners();
    try {
      final result = await service.adminReport(requested);
      if (requestId != _reportRequestId) return;
      reportState = ReportReady(result);
    } catch (error) {
      if (requestId != _reportRequestId) return;
      final failure = _reportFailure(error);
      reportState = canKeepPrior && prior != null
          ? ReportStale(prior, failure)
          : ReportFailed(failure);
    } finally {
      if (requestId == _reportRequestId) {
        notifyListeners();
      }
    }
  }

  static ReportFailure _reportFailure(Object error) {
    final text = error.toString().toLowerCase();
    if (error is ReportContractException) {
      return switch (error.code) {
        ReportContractFailureCode.unreconciledFacility => const ReportFailure(
          supportReference: 'RPT-CONTRACT-FACILITY-SCOPE',
          explanation:
              'The report included data outside this report’s facility scope, so it was not shown.',
        ),
        ReportContractFailureCode.incompleteDemandGrid => const ReportFailure(
          supportReference: 'RPT-CONTRACT-DEMAND-GRID',
          explanation:
              'The demand analysis was incomplete, so the report was not shown.',
        ),
        ReportContractFailureCode.scopeMismatch => const ReportFailure(
          supportReference: 'RPT-CONTRACT-SCOPE',
          explanation:
              'The reporting service returned a result for a different filter selection.',
        ),
        ReportContractFailureCode.unsupportedVersion => const ReportFailure(
          supportReference: 'RPT-CONTRACT-VERSION',
          explanation:
              'The reporting service is still using an older report contract. Apply the latest report migration before loading this page.',
        ),
        ReportContractFailureCode.unreconciledTotals => const ReportFailure(
          supportReference: 'RPT-CONTRACT-TOTALS',
          explanation:
              'The report totals did not reconcile, so the report was not shown.',
        ),
        ReportContractFailureCode.invalidOccurrence => const ReportFailure(
          supportReference: 'RPT-CONTRACT-OCCURRENCE',
          explanation:
              'A booked occurrence in the report was invalid, so the report was not shown.',
        ),
        ReportContractFailureCode.invalidResponse => const ReportFailure(
          supportReference: 'RPT-CONTRACT-RESPONSE',
          explanation:
              'The reporting service returned data that could not be verified.',
        ),
      };
    }
    if (error is FormatException) {
      return const ReportFailure(
        supportReference: 'RPT-CONTRACT-RESPONSE',
        explanation:
            'The reporting service returned data that could not be verified.',
      );
    }
    if (text.contains('pgrst202') ||
        text.contains('could not find the function') ||
        text.contains('schema cache')) {
      return const ReportFailure(
        supportReference: 'RPT-SERVICE-SCHEMA-CACHE',
        explanation:
            'Reporting is temporarily unavailable while the database service is updated.',
      );
    }
    if (text.contains('42501') ||
        text.contains('administrator access required') ||
        text.contains('permission denied')) {
      return const ReportFailure(
        supportReference: 'RPT-AUTH-PERMISSION',
        explanation:
            'Your account does not have permission to view this report.',
      );
    }
    if (text.contains('22023') || text.contains('invalid report range')) {
      return const ReportFailure(
        supportReference: 'RPT-SCOPE-RANGE',
        explanation:
            'The selected reporting range is invalid. Choose another range.',
      );
    }
    if (text.contains('socket') ||
        text.contains('network') ||
        text.contains('timeout') ||
        text.contains('failed host lookup') ||
        text.contains('connection')) {
      return const ReportFailure(
        supportReference: 'RPT-NETWORK',
        explanation:
            'Reports could not connect to SmartReserve. Check the connection and retry.',
      );
    }
    return const ReportFailure(
      supportReference: 'RPT-SERVICE-UNKNOWN',
      explanation: 'Reports could not be loaded. Retry in a moment.',
    );
  }

  Future<void> refreshAudit({AuditQuery? query}) async {
    final service = backend;
    if (service == null || !isInternalAdmin) return;
    auditQuery = query ?? auditQuery;
    auditLoading = true;
    auditError = null;
    notifyListeners();
    try {
      final page = await service.auditEntries(auditQuery);
      remoteAudit = page.entries;
      auditActors = page.actors;
      auditTotal = page.total;
    } catch (error) {
      auditError = 'Audit log could not load: $error';
    } finally {
      auditLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreAudit() async {
    final service = backend;
    if (service == null ||
        auditLoadingMore ||
        remoteAudit.length >= auditTotal ||
        remoteAudit.isEmpty)
      // ignore: curly_braces_in_flow_control_structures
      return;
    auditLoadingMore = true;
    notifyListeners();
    try {
      final last = remoteAudit.last;
      final page = await service.auditEntries(
        auditQuery.copyWith(beforeCreatedAt: last.createdAt, beforeId: last.id),
      );
      remoteAudit = [...remoteAudit, ...page.entries];
    } catch (error) {
      auditError = 'More audit entries could not load: $error';
    } finally {
      auditLoadingMore = false;
      notifyListeners();
    }
  }

  Future<List<AuditEntry>> auditExportRows() async {
    final service = backend;
    if (service == null) return audit;
    final rows = <AuditEntry>[];
    var query = auditQuery;
    while (true) {
      final page = await service.auditEntries(query);
      rows.addAll(page.entries);
      if (rows.length >= page.total || page.entries.isEmpty) break;
      final last = page.entries.last;
      query = query.copyWith(
        beforeCreatedAt: last.createdAt,
        beforeId: last.id,
      );
    }
    return rows;
  }

  void leaveProfile() => goTo(_profileOrigin);

  bool notificationsOpen = false;

  void toggleNotifications() {
    notificationsOpen = !notificationsOpen;
    notifyListeners();
  }

  void closeOverlays() {
    if (!notificationsOpen) return;
    notificationsOpen = false;
    notifyListeners();
  }

  late List<Facility> facilities;
  late List<ReservationRequest> requests;
  late List<VerificationSubmission> verifications;
  late List<Account> accounts;
  late List<OrganizationUnit> organizationUnits;
  late List<OrganizationAccountSlot> organizationSlots;
  late List<AuditEntry> audit;
  late List<Booking> bookings;
  ReportScope? reportScope;
  ReportLoadState reportState = const ReportInitialLoading();
  int _reportRequestId = 0;
  ReportSnapshot? get reportSnapshot => reportState.snapshot;
  bool get reportsLoading => reportState.isLoading;
  String? get reportsError => reportState.failure?.explanation;
  bool get reportsStale => reportState.isStale;
  List<AuditEntry> remoteAudit = [];
  List<String> auditActors = [];
  int auditTotal = 0;
  bool auditLoading = false;
  bool auditLoadingMore = false;
  String? auditError;
  AuditQuery auditQuery = const AuditQuery();
  List<BackendNotification> notifications = [];
  Map<String, bool> notificationPreferences = {
    'Decision on my requests': true,
    'Reminder the day before': true,
    'New facilities on campus': false,
  };

  final Set<String> feedbackSubmitting = {};
  FeedbackQuery feedbackQuery = const FeedbackQuery();
  List<FeedbackEntry> feedbackEntries = [];
  int feedbackEntriesTotal = 0;
  FeedbackSummary feedbackSummaryData = const FeedbackSummary();
  FeedbackSentimentAnalytics feedbackSentimentAnalyticsData =
      const FeedbackSentimentAnalytics();
  bool feedbackLoading = false;
  bool feedbackAnalyticsLoading = false;
  String? feedbackError;
  String? feedbackAnalyticsError;
  final Set<String> feedbackSentimentRetrying = {};
  int _feedbackRequestId = 0;

  // Loyalty
  LoyaltySummary? loyalty;
  bool loyaltyLoading = false;
  String? loyaltyError;
  final Set<String> redemptionsPending = {};
  final Set<String> discountClaimsPending = {};
  List<LoyaltyBalanceRow> loyaltyBalances = [];
  bool loyaltyBalancesLoading = false;
  String? loyaltyBalancesError;
  final Map<String, List<LoyaltyTransaction>> loyaltyLedgerByUser = {};
  final Set<String> loyaltyLedgerLoading = {};
  final Map<String, String> loyaltyLedgerErrors = {};
  List<LoyaltyDiscountOffer> loyaltyDiscountOffers = [];
  bool loyaltyDiscountOffersLoading = false;
  String? loyaltyDiscountOffersError;
  String? loyaltyDiscountOfferSaveError;
  List<LoyaltyAdminClaimRow> loyaltyAdminClaims = [];
  bool loyaltyAdminClaimsLoading = false;
  String? loyaltyAdminClaimsError;
  bool pendingLoyaltyOpen = false;

  // Anomalies
  AnomalyFilters anomalyFilters = const AnomalyFilters();
  List<ReservationAnomaly> anomalyRows = [];
  AnomalyMetrics anomalyMetrics = const AnomalyMetrics();
  Map<String, dynamic>? _anomalyCursor;
  bool anomalyHasMore = false;
  bool anomalyLoading = false;
  bool anomalyLoadingMore = false;
  String? anomalyError;
  int _anomalyRequestId = 0;
  String? selectedAnomalyId;
  AnomalyDetail? selectedAnomalyDetail;
  bool anomalyDetailLoading = false;
  String? anomalyDetailError;
  final Map<String, RenterRiskSummary> _riskSummaryByRequest = {};
  final Set<String> _riskSummaryLoading = {};
  final Map<String, Timer> _riskSummaryPollTimers = {};
  final Map<String, int> _riskSummaryPollAttempts = {};
  final Set<String> _riskSummaryPollExhausted = {};

  static const _riskSummaryPollInterval = Duration(seconds: 5);
  static const _riskSummaryPollMaxAttempts =
      18; // ~90s: one missed 60s cron tick + margin

  int get anomalyActiveHighCriticalCount =>
      anomalyMetrics.highCount + anomalyMetrics.criticalCount;

  RenterRiskSummary? riskSummaryFor(String requestId) =>
      _riskSummaryByRequest[requestId];

  bool riskSummaryLoading(String requestId) =>
      _riskSummaryLoading.contains(requestId);

  bool riskSummaryPollExhausted(String requestId) =>
      _riskSummaryPollExhausted.contains(requestId);

  void _cancelRiskSummaryPoll(String requestId) {
    _riskSummaryPollTimers.remove(requestId)?.cancel();
    _riskSummaryPollAttempts.remove(requestId);
  }

  void _cancelAllRiskSummaryPolls() {
    for (final timer in _riskSummaryPollTimers.values) {
      timer.cancel();
    }
    _riskSummaryPollTimers.clear();
    _riskSummaryPollAttempts.clear();
    _riskSummaryPollExhausted.clear();
  }

  void _scheduleRiskSummaryPoll(String requestId) {
    if (_riskSummaryPollTimers.containsKey(requestId)) return;
    final attempts = _riskSummaryPollAttempts[requestId] ?? 0;
    if (attempts >= _riskSummaryPollMaxAttempts) {
      if (_riskSummaryPollExhausted.add(requestId)) notifyListeners();
      return;
    }
    _riskSummaryPollExhausted.remove(requestId);
    _riskSummaryPollTimers[requestId] = Timer(_riskSummaryPollInterval, () {
      _riskSummaryPollTimers.remove(requestId);
      _riskSummaryPollAttempts[requestId] = attempts + 1;
      unawaited(loadReservationRiskSummary(requestId));
    });
  }

  /// Shared trigger for every call site that mutates `selectedRequestId`.
  void _syncSelectedRequestRiskSummary(String? previousId, String? id) {
    if (previousId != null && previousId != id) {
      _cancelRiskSummaryPoll(previousId);
    }
    if (id == null || _useDemoData || !isAdmin) return;
    final cached = _riskSummaryByRequest[id];
    if (cached == null) {
      unawaited(loadReservationRiskSummary(id));
    } else if (cached.evaluationPending) {
      _scheduleRiskSummaryPoll(id);
    }
  }

  void _clearAnomalyState() {
    _anomalyRequestId++;
    anomalyFilters = const AnomalyFilters();
    anomalyRows = [];
    anomalyMetrics = const AnomalyMetrics();
    _anomalyCursor = null;
    anomalyHasMore = false;
    anomalyLoading = false;
    anomalyLoadingMore = false;
    anomalyError = null;
    selectedAnomalyId = null;
    selectedAnomalyDetail = null;
    anomalyDetailLoading = false;
    anomalyDetailError = null;
    _riskSummaryByRequest.clear();
    _riskSummaryLoading.clear();
    _cancelAllRiskSummaryPolls();
  }

  Future<void> refreshAnomalyCenter({AnomalyFilters? filters}) async {
    final service = backend;
    if (_useDemoData || service == null || !isAdmin) return;
    final requested = filters ?? anomalyFilters;
    final requestId = ++_anomalyRequestId;
    anomalyFilters = requested;
    anomalyLoading = true;
    anomalyError = null;
    notifyListeners();
    try {
      final page = await service.anomalyCenter(filters: requested, limit: 50);
      if (requestId != _anomalyRequestId) return;
      anomalyRows = page.rows;
      anomalyMetrics = page.metrics;
      _anomalyCursor = page.nextCursor;
      anomalyHasMore = page.nextCursor != null;
    } catch (error) {
      if (requestId == _anomalyRequestId) {
        anomalyError = friendlyBackendMessage('$error');
      }
    } finally {
      if (requestId == _anomalyRequestId) {
        anomalyLoading = false;
        notifyListeners();
      }
    }
  }

  void setAnomalyFilters(AnomalyFilters filters) {
    unawaited(refreshAnomalyCenter(filters: filters));
  }

  Future<void> loadMoreAnomalies() async {
    final service = backend;
    final cursor = _anomalyCursor;
    if (service == null ||
        anomalyLoadingMore ||
        !anomalyHasMore ||
        cursor == null) {
      return;
    }
    anomalyLoadingMore = true;
    notifyListeners();
    try {
      final page = await service.anomalyCenter(
        filters: anomalyFilters,
        cursor: cursor,
        limit: 50,
      );
      anomalyRows = [...anomalyRows, ...page.rows];
      anomalyMetrics = page.metrics;
      _anomalyCursor = page.nextCursor;
      anomalyHasMore = page.nextCursor != null;
    } catch (error) {
      anomalyError = friendlyBackendMessage('$error');
    } finally {
      anomalyLoadingMore = false;
      notifyListeners();
    }
  }

  void selectAnomaly(String? id) {
    selectedAnomalyId = id;
    selectedAnomalyDetail = null;
    anomalyDetailError = null;
    notifyListeners();
    if (id != null) unawaited(loadAnomalyDetail(id));
  }

  Future<void> loadAnomalyDetail(String id) async {
    final service = backend;
    if (service == null) return;
    anomalyDetailLoading = true;
    anomalyDetailError = null;
    notifyListeners();
    try {
      final detail = await service.anomalyDetail(id);
      if (selectedAnomalyId != id) return;
      selectedAnomalyDetail = detail;
    } catch (error) {
      if (selectedAnomalyId == id) {
        anomalyDetailError = friendlyBackendMessage('$error');
      }
    } finally {
      if (selectedAnomalyId == id) {
        anomalyDetailLoading = false;
        notifyListeners();
      }
    }
  }

  String _anomalyActionLabel(String action) => switch (action) {
    'acknowledge' => 'Anomaly acknowledged.',
    'resolve' => 'Anomaly resolved.',
    'false_positive' => 'Marked as false positive.',
    _ => 'Anomaly updated.',
  };

  Future<bool> transitionAnomaly({
    required String anomalyId,
    required String action,
    String? reasonCode,
    String? note,
  }) async {
    final service = backend;
    if (service == null) return false;
    try {
      final detail = await service.transitionReservationAnomaly(
        anomalyId: anomalyId,
        action: action,
        reasonCode: reasonCode,
        note: note,
      );
      if (selectedAnomalyId == anomalyId) selectedAnomalyDetail = detail;
      anomalyRows = [
        for (final row in anomalyRows)
          if (row.id == anomalyId) detail.anomaly else row,
      ];
      notifyListeners();
      unawaited(refreshAnomalyCenter());
      showToast(ToastMessage.success(_anomalyActionLabel(action)));
      return true;
    } catch (error) {
      showToast(
        ToastMessage(
          friendlyBackendMessage('$error'),
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    }
  }

  void openReservationFromAnomaly(String? requestId) {
    goTo(AppView.reservations);
    if (requestId != null) selectRequest(requestId);
  }

  Future<void> loadReservationRiskSummary(String requestId) =>
      _fetchRiskSummary(
        requestId,
        (service) => service.reservationRiskSummary(requestId),
      );

  /// Forces an immediate server-side evaluation (bypassing the pg_cron
  /// queue) and applies the result — used by the risk card's manual
  /// "Refresh" action once polling has been exhausted or is stalled.
  Future<void> refreshReservationRiskSummary(String requestId) async {
    _cancelRiskSummaryPoll(requestId);
    _riskSummaryPollExhausted.remove(requestId);
    await _fetchRiskSummary(
      requestId,
      (service) => service.evaluateReservationRiskNow(requestId),
    );
  }

  Future<void> _fetchRiskSummary(
    String requestId,
    Future<RenterRiskSummary> Function(SmartReserveBackend service) fetch,
  ) async {
    final service = backend;
    if (_useDemoData || service == null || !isAdmin) return;
    if (_riskSummaryLoading.contains(requestId)) return;
    _riskSummaryLoading.add(requestId);
    notifyListeners();
    try {
      final summary = await fetch(service);
      _riskSummaryByRequest[requestId] = summary;
      final request = requestById(requestId);
      if (request != null) request.noShows = summary.noShowOccurrences30d;
      if (summary.evaluationPending) {
        _scheduleRiskSummaryPoll(requestId);
      } else {
        _cancelRiskSummaryPoll(requestId);
        _riskSummaryPollExhausted.remove(requestId);
      }
    } catch (error) {
      debugPrint('Risk summary could not load: $error');
      if (_riskSummaryByRequest[requestId]?.evaluationPending == true) {
        _scheduleRiskSummaryPoll(requestId);
      }
    } finally {
      _riskSummaryLoading.remove(requestId);
      notifyListeners();
    }
  }

  Future<bool> correctOccurrenceAttendance({
    required String occurrenceId,
    required String targetStage,
    required String reason,
  }) async {
    final service = backend;
    if (service == null) return false;
    try {
      await service.correctOccurrenceAttendance(
        occurrenceId: occurrenceId,
        targetStage: targetStage,
        reason: reason,
      );
      await refreshReservations();
      showToast(ToastMessage.success('Attendance corrected.'));
      return true;
    } catch (error) {
      showToast(
        ToastMessage(
          friendlyBackendMessage('$error'),
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> checkReservationOverlaps({
    required List<DateTime> startsAt,
    required List<DateTime> endsAt,
    String? excludeRequestId,
  }) async {
    final service = backend;
    if (_useDemoData || service == null) return const [];
    try {
      return await service.checkMyReservationOverlaps(
        startsAt: startsAt,
        endsAt: endsAt,
        excludeRequestId: excludeRequestId,
      );
    } catch (error) {
      debugPrint('Overlap check could not load: $error');
      return const [];
    }
  }

  final Map<String, BackendReservation> _backendReservations = {};
  SmartReserveBackend? backend;
  SmartReserveCoreBackend? get _coreBackend {
    final service = backend;
    if (service is SmartReserveCoreBackend) {
      return service as SmartReserveCoreBackend;
    }
    return null;
  }

  SessionProfile? sessionProfile;
  BackendVerification? myVerification;
  Account? _sessionAccount;
  StreamSubscription<List<BackendVerification>>? _verificationSubscription;
  StreamSubscription<List<BackendFacility>>? _facilitySubscription;
  StreamSubscription<List<BackendAccount>>? _accountSubscription;
  StreamSubscription<List<BackendReservation>>? _reservationSubscription;
  StreamSubscription<List<BackendNotification>>? _notificationSubscription;
  StreamSubscription<List<BackendLoyaltyTransaction>>? _loyaltySubscription;
  StreamSubscription<void>? _feedbackSentimentSubscription;

  bool get hasSession => sessionProfile != null;
  bool get isInternalAdmin => sessionProfile?.isInternalAdmin ?? false;
  bool get isExternalAdmin => sessionProfile?.isExternalAdmin ?? false;
  bool get isAdmin => sessionProfile?.isAdmin ?? false;
  bool get _currentUserIsGuestPriced =>
      !isAdmin &&
      userAccount.role == AccountRole.user &&
      userAccount.status == AccountStatus.active &&
      userAccount.pricingAudience == 'guest';
  bool get loyaltyAvailableForCurrentUser =>
      _currentUserIsGuestPriced && (loyalty?.eligible ?? _useDemoData);
  bool get shouldRefreshLoyaltyForCurrentUser => _currentUserIsGuestPriced;

  static const LoyaltySummary _ineligibleLoyalty = LoyaltySummary(
    eligible: false,
  );

  void _clearAdminLoyaltyState() {
    loyaltyBalances = [];
    loyaltyBalancesLoading = false;
    loyaltyBalancesError = null;
    loyaltyLedgerByUser.clear();
    loyaltyLedgerLoading.clear();
    loyaltyLedgerErrors.clear();
    loyaltyDiscountOffers = [];
    loyaltyDiscountOffersLoading = false;
    loyaltyDiscountOffersError = null;
    loyaltyDiscountOfferSaveError = null;
    loyaltyAdminClaims = [];
    loyaltyAdminClaimsLoading = false;
    loyaltyAdminClaimsError = null;
  }

  void configureBackend(SmartReserveBackend service) {
    backend = service;
  }

  bool get assistantHistoryAvailable =>
      !_useDemoData && backend != null && hasSession;

  Future<List<BackendAssistantConversation>> assistantConversations() async {
    if (!assistantHistoryAvailable) return const [];
    return backend!.assistantConversations();
  }

  Future<BackendAssistantConversation> createAssistantConversation({
    required String title,
    Map<String, dynamic> activeDraft = const {},
  }) {
    final service = backend;
    if (!assistantHistoryAvailable || service == null) {
      throw StateError('Chat history requires a signed-in account.');
    }
    return service.createAssistantConversation(
      title: title,
      activeDraft: activeDraft,
    );
  }

  Future<List<BackendAssistantMessage>> assistantMessages(
    String conversationId,
  ) async {
    if (!assistantHistoryAvailable) return const [];
    return backend!.assistantMessages(conversationId);
  }

  Future<void> appendAssistantMessages(
    String conversationId,
    List<BackendAssistantMessage> messages,
  ) async {
    if (!assistantHistoryAvailable) return;
    await backend!.appendAssistantMessages(conversationId, messages);
  }

  Future<void> updateAssistantConversation(
    String conversationId, {
    String? title,
    Map<String, dynamic>? activeDraft,
  }) async {
    if (!assistantHistoryAvailable) return;
    await backend!.updateAssistantConversation(
      conversationId,
      title: title,
      activeDraft: activeDraft,
    );
  }

  Future<void> initializeBackend() async {
    await loadThemePreference();
    final service = backend;
    if (service == null) return;
    await applyBackendProfile(await service.currentProfile());
  }

  Future<void> applyBackendProfile(SessionProfile? profile) async {
    sessionProfile = profile;
    _syncSessionAccount();
    _clearAnomalyState();
    _verificationSubscription?.cancel();
    _verificationSubscription = null;
    _facilitySubscription?.cancel();
    _facilitySubscription = null;
    _accountSubscription?.cancel();
    _accountSubscription = null;
    _reservationSubscription?.cancel();
    _reservationSubscription = null;
    _notificationSubscription?.cancel();
    _notificationSubscription = null;
    _loyaltySubscription?.cancel();
    _loyaltySubscription = null;
    _feedbackSentimentSubscription?.cancel();
    _feedbackSentimentSubscription = null;
    if (profile == null) {
      _reportRequestId++;
      _feedbackRequestId++;
      reportScope = null;
      reportState = const ReportInitialLoading();
      initialReportFacilityId = null;
      view = AppView.auth;
      verifications = [];
      myVerification = null;
      _sessionAccount = null;
      facilities = [];
      requests = _useDemoData ? seedRequests() : [];
      bookings = _useDemoData
          ? [...seedBookings(), ...seriesDemoBookings()]
          : [];
      notifications = [];
      _backendReservations.clear();
      userCalendarSlots = [];
      userCalendarError = null;
      userCalendarLoading = false;
      _userCalendarRequestId++;
      if (!_useDemoData) accounts = [];
      accountsLoading = false;
      accountsError = null;
      feedbackEntries = [];
      feedbackEntriesTotal = 0;
      feedbackSummaryData = const FeedbackSummary();
      feedbackSentimentAnalyticsData = const FeedbackSentimentAnalytics();
      feedbackLoading = false;
      feedbackAnalyticsLoading = false;
      feedbackError = null;
      feedbackAnalyticsError = null;
      feedbackSentimentRetrying.clear();
      loyalty = null;
      loyaltyError = null;
      _clearAdminLoyaltyState();
      notifyListeners();
      return;
    }

    // Authentication is complete once the profile has been accepted. Route the
    // session before loading workspace data so a later feature failure cannot
    // strand a valid user on the sign-in screen.
    view = profile.isAdmin
        ? AppView.facilities
        : profile.isActive &&
              profile.onboardingComplete &&
              !profile.mustChangePassword &&
              profile.accountAccessType != 'legacy_unassigned'
        ? AppView.userApp
        : AppView.auth;
    notifyListeners();

    await _runSessionRefresh('facilities', refreshFacilities);
    _facilitySubscription = backend?.facilityStream().listen(
      _applyFacilityRows,
      onError: (Object error) {
        facilitiesError = 'Facilities could not refresh: $error';
        facilitiesLoading = false;
        notifyListeners();
      },
    );
    await _runSessionRefresh('reservations', refreshReservations);
    _reservationSubscription = backend?.reservationStream().listen(
      _applyReservationRows,
      onError: (Object error) {
        reservationsError = 'Reservations could not refresh: $error';
        reservationsLoading = false;
        notifyListeners();
      },
    );
    await _runSessionRefresh('notifications', refreshNotifications);
    _notificationSubscription = backend?.notificationStream().listen(
      _applyNotifications,
      onError: (Object error) {
        notificationsError = 'Notifications could not refresh: $error';
        notifyListeners();
      },
    );
    if (profile.isInternalAdmin) {
      _clearAdminLoyaltyState();
      _syncFeedbackSentimentSubscription();
      await _runSessionRefresh('accounts', refreshAccounts);
      _accountSubscription = backend?.accountStream().listen(
        _applyBackendAccounts,
        onError: (Object error) {
          accountsError = 'Accounts could not refresh: ${_accountError(error)}';
          accountsLoading = false;
          notifyListeners();
        },
      );
      await _runSessionRefresh('verifications', refreshVerifications);
      _verificationSubscription = backend?.verificationStream().listen(
        (_) {
          unawaited(refreshVerifications());
        },
        onError: (Object error) =>
            debugPrint('Verifications live refresh failed: $error'),
      );
      unawaited(refreshAnomalyCenter());
      await _runSessionRefresh('initial report', _applyInitialReportLink);
    } else if (profile.isExternalAdmin) {
      _syncFeedbackSentimentSubscription();
      if (_useDemoData) {
        final paidRequesterNames = {
          for (final request in requests)
            if (!request.heldForVerification &&
                request.paymentStatus != PaymentTrackingStatus.notRequired)
              request.requester,
        };
        accounts = [
          for (final account in accounts)
            if (account.role == AccountRole.user &&
                account.verification != VerificationState.verified &&
                paidRequesterNames.contains(account.name))
              account,
        ];
      } else {
        await _runSessionRefresh('accounts', refreshAccounts);
      }
      unawaited(refreshAnomalyCenter());
      await _runSessionRefresh('initial report', _applyInitialReportLink);
    } else {
      _clearAdminLoyaltyState();
      if (!_useDemoData) accounts = [];
      await _runSessionRefresh('your verification', () async {
        myVerification = await backend?.currentVerification();
        verifications = myVerification == null
            ? []
            : [_toVerification(myVerification!)];
      });
      _syncSessionAccount();
      _verificationSubscription = backend?.verificationStream().listen(
        (_) {
          unawaited(refreshMyVerification());
        },
        onError: (Object error) =>
            debugPrint('Verification live refresh failed: $error'),
      );
      await _runSessionRefresh('loyalty', refreshLoyalty);
      _syncLoyaltySubscription();
    }
    notifyListeners();
  }

  Future<void> _runSessionRefresh(
    String area,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error, stackTrace) {
      // Individual feature refreshers own their visible retry state. This
      // boundary prevents an uncovered failure from being misreported as an
      // authentication failure after the session is already established.
      debugPrint('SmartReserve $area bootstrap failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  String? initialReportFacilityId;

  Future<void> _applyInitialReportLink() async {
    final link = readInitialReportLink();
    if (link == null || !isAdmin) return;
    final category =
        link.category != null &&
            facilities.any((facility) => facility.category == link.category)
        ? link.category
        : null;
    initialReportFacilityId = link.facilityId;
    view = AppView.reports;
    await refreshReports(
      scope: ReportScope.forRange(link.range, category: category),
    );
  }

  Future<void> refreshMyVerification() async {
    myVerification = await backend?.currentVerification();
    verifications = myVerification == null
        ? []
        : [_toVerification(myVerification!)];
    _syncSessionAccount();
    await refreshLoyalty();
    _syncLoyaltySubscription();
    notifyListeners();
  }

  void _syncLoyaltySubscription() {
    _loyaltySubscription?.cancel();
    _loyaltySubscription = null;
    final service = _coreBackend;
    if (_useDemoData || service == null || !loyaltyAvailableForCurrentUser) {
      return;
    }
    _loyaltySubscription = service.loyaltyTransactionStream().listen(
      (_) {
        unawaited(refreshLoyalty());
      },
      onError: (Object error) =>
          debugPrint('Loyalty live refresh failed: $error'),
    );
  }

  void _syncFeedbackSentimentSubscription() {
    _feedbackSentimentSubscription?.cancel();
    _feedbackSentimentSubscription = null;
    final service = _coreBackend;
    if (_useDemoData || service == null || !isAdmin) return;
    _feedbackSentimentSubscription = service
        .feedbackSentimentAnalysisStream()
        .listen(
          (_) {
            if (view == AppView.feedback) unawaited(refreshFeedback());
          },
          onError: (Object error) =>
              debugPrint('Feedback sentiment live refresh failed: $error'),
        );
  }

  VerificationState get _sessionVerification {
    final submissionStatus = myVerification?.status;
    if (submissionStatus != null) {
      return switch (submissionStatus) {
        'approved' => VerificationState.verified,
        'rejected' => VerificationState.rejected,
        'pending' || 'changes_requested' => VerificationState.pending,
        _ => VerificationState.none,
      };
    }
    return VerificationState.fromRaw(
      sessionProfile?.verificationStatus ?? 'none',
    );
  }

  void _syncSessionAccount() {
    final profile = sessionProfile;
    if (profile == null || profile.isAdmin) {
      _sessionAccount = null;
      return;
    }

    _sessionAccount = Account(
      id: profile.id,
      name: profile.fullName,
      email: profile.email,
      role: AccountRole.fromRaw(profile.role),
      unit: profile.unit ?? '',
      idNumber: profile.campusId ?? '',
      verification: _sessionVerification,
      status: AccountStatus.fromRaw(profile.accountStatus),
      reservations: 0,
      lastActive: 'Now',
      joined: _formatProfileDate(profile.createdAt),
      noShows: 0,
      isSelf: true,
      suspendReason: profile.suspensionReason,
      suspendUntil: profile.suspendedUntil == null
          ? null
          : _accountDate(profile.suspendedUntil),
      organizationSlotId: profile.organizationSlotId,
      organizationSlotLabel: profile.organizationSlotLabel,
      organizationUnitId: profile.organizationUnitId,
      organizationUnitName: profile.organizationUnitName,
      organizationUnitCode: profile.organizationUnitCode,
      organizationUnitType: profile.organizationUnitType,
      organizationUnitBookingAudience: profile.organizationUnitBookingAudience,
      accountAccessType: AccountAccessType.fromRaw(profile.accountAccessType),
      mustChangePassword: profile.mustChangePassword,
      passwordIssuedAt: profile.passwordIssuedAt,
    );
  }

  Future<void> refreshVerifications() async {
    final service = backend;
    if (service == null || !isInternalAdmin) return;
    final rows = await service.verifications();
    verifications = rows.map(_toVerification).toList();
    notifyListeners();
  }

  bool accountsLoading = false;
  String? accountsError;
  bool organizationRegistryLoading = false;
  String? organizationRegistryError;

  Future<void> refreshAccounts() async {
    final service = backend;
    if (service == null || (!isInternalAdmin && !isExternalAdmin)) return;
    accountsLoading = true;
    accountsError = null;
    notifyListeners();
    try {
      _applyBackendAccounts(
        isExternalAdmin
            ? await service.externalClients()
            : await service.accounts(),
      );
    } catch (error) {
      accountsLoading = false;
      accountsError = 'Accounts could not be loaded: ${_accountError(error)}';
      notifyListeners();
    }
  }

  void _applyBackendAccounts(List<BackendAccount> rows) {
    accounts = rows.map(_toAccount).toList();
    accountsLoading = false;
    accountsError = null;
    notifyListeners();
  }

  Account _toAccount(BackendAccount row) => Account(
    id: row.id,
    name: row.fullName.trim().isEmpty ? row.email : row.fullName,
    email: row.email,
    role: AccountRole.fromRaw(row.role),
    unit: row.unit.trim().isEmpty ? '—' : row.unit,
    idNumber: row.campusId.trim().isEmpty ? '—' : row.campusId,
    verification: VerificationState.fromRaw(row.verificationStatus),
    status: AccountStatus.fromRaw(row.accountStatus),
    reservations: row.reservationCount,
    lastActive: row.isSelf
        ? 'Now'
        : _relativeAccountTime(
            row.lastSignInAt ?? row.lastReservationAt,
            never: 'Never',
          ),
    joined: _accountDate(row.createdAt),
    noShows: 0,
    isSelf: row.isSelf,
    suspendUntil: row.suspendedUntil == null
        ? null
        : _accountDate(row.suspendedUntil),
    suspendReason: row.suspensionReason,
    invitationSentAt: row.invitationSentAt,
    lastActiveAt: row.lastSignInAt,
    joinedAt: row.createdAt,
    activityMetricsAvailable:
        row.activityMetricsAvailable || row.reservationCount > 0,
    organizationSlotId: row.organizationSlotId,
    organizationSlotLabel: row.organizationSlotLabel,
    organizationUnitId: row.organizationUnitId,
    organizationUnitName: row.organizationUnitName,
    organizationUnitCode: row.organizationUnitCode,
    organizationUnitType: row.organizationUnitType,
    organizationUnitBookingAudience: row.organizationUnitBookingAudience,
    accountAccessType: AccountAccessType.fromRaw(row.accountAccessType),
    mustChangePassword: row.mustChangePassword,
    passwordIssuedAt: row.passwordIssuedAt,
  );

  void _upsertBackendAccount(BackendAccount row) {
    final account = _toAccount(row);
    final index = accounts.indexWhere((item) => item.id == account.id);
    if (index == -1) {
      accounts = [account, ...accounts];
    } else {
      accounts = [...accounts]..[index] = account;
    }
    accountsError = null;
    notifyListeners();
  }

  OrganizationUnit _toOrganizationUnit(BackendOrganizationUnit row) =>
      OrganizationUnit(
        id: row.id,
        parentId: row.parentId,
        name: row.name,
        code: row.code,
        unitType: row.unitType,
        active: row.active,
        requiresRepresentative: row.requiresRepresentative,
        bookingAudience: row.bookingAudience,
      );

  OrganizationAccountSlot _toOrganizationSlot(
    BackendOrganizationAccountSlot row,
  ) => OrganizationAccountSlot(
    id: row.id,
    unitId: row.unitId,
    label: row.label,
    active: row.active,
    assignedProfileId: row.assignedProfileId,
    assignedName: row.assignedName,
    assignedEmail: row.assignedEmail,
    unit: row.unit == null ? null : _toOrganizationUnit(row.unit!),
  );

  void _upsertOrganizationUnit(BackendOrganizationUnit row) {
    final unit = _toOrganizationUnit(row);
    final index = organizationUnits.indexWhere((item) => item.id == unit.id);
    if (index == -1) {
      organizationUnits = [...organizationUnits, unit];
    } else {
      organizationUnits = [...organizationUnits]..[index] = unit;
    }
  }

  Future<void> refreshOrganizationRegistry() async {
    final service = backend;
    if (service == null || !isInternalAdmin) return;
    organizationRegistryLoading = true;
    organizationRegistryError = null;
    notifyListeners();
    try {
      final units = await service.organizationUnits();
      final slots = await service.organizationSlots();
      organizationUnits = units.map(_toOrganizationUnit).toList();
      organizationSlots = slots.map(_toOrganizationSlot).toList();
      organizationRegistryLoading = false;
      notifyListeners();
    } catch (error) {
      organizationRegistryLoading = false;
      organizationRegistryError =
          'Organization registry could not be loaded: ${_accountError(error)}';
      notifyListeners();
    }
  }

  Future<String?> saveOrganizationUnit({
    String? unitId,
    String? parentId,
    required String name,
    String? code,
    required String unitType,
    required bool requiresRepresentative,
    String? bookingAudience,
  }) async {
    final service = backend;
    if (service == null || !isInternalAdmin) {
      return 'Only an internal admin can manage organizations.';
    }
    final normalizedName = name.trim().toLowerCase();
    if (normalizedName.length < 2) {
      return 'Enter an organization name with at least two characters.';
    }
    final duplicate = organizationUnits.any(
      (unit) =>
          unit.active &&
          unit.id != unitId &&
          unit.parentId == parentId &&
          unit.name.trim().toLowerCase() == normalizedName,
    );
    if (duplicate) {
      return 'An active organization named "${name.trim()}" already exists under this parent.';
    }
    try {
      final row = unitId == null
          ? await service.createOrganizationUnit(
              parentId: parentId,
              name: name,
              code: code,
              unitType: unitType,
              requiresRepresentative: requiresRepresentative,
              bookingAudience: bookingAudience,
            )
          : await service.updateOrganizationUnit(
              unitId: unitId,
              parentId: parentId,
              name: name,
              code: code,
              unitType: unitType,
              bookingAudience: bookingAudience,
            );
      _upsertOrganizationUnit(row);
      await refreshOrganizationRegistry();
      organizationRegistryError = null;
      notifyListeners();
      if (unitId == null) {
        showToast(ToastMessage('Organization "${row.name}" created.'));
      } else {
        showToast(ToastMessage('Organization "${row.name}" updated.'));
      }
      return null;
    } catch (error) {
      return _accountActionError(error, 'Organization was not saved.');
    }
  }

  Future<String?> archiveOrganizationUnit(String unitId) async {
    final service = backend;
    if (service == null || !isInternalAdmin) {
      return 'Only an internal admin can archive organizations.';
    }
    try {
      _upsertOrganizationUnit(await service.archiveOrganizationUnit(unitId));
      notifyListeners();
      return null;
    } catch (error) {
      return _accountActionError(error, 'Organization was not archived.');
    }
  }

  Future<String?> saveOrganizationSlot({
    String? slotId,
    required String unitId,
    required String label,
    bool active = true,
  }) async {
    return 'Organization slots are created automatically with account-bearing organizations.';
  }

  Future<String?> archiveOrganizationSlot(String slotId) async {
    return 'Archive the organization unit after removing its representative.';
  }

  Future<String?> assignOrganizationRepresentative({
    required String profileId,
    required String slotId,
  }) async {
    final service = backend;
    if (service == null || !isInternalAdmin) {
      return 'Only an internal admin can assign representatives.';
    }
    try {
      _upsertBackendAccount(
        await service.assignOrganizationRepresentative(
          profileId: profileId,
          slotId: slotId,
        ),
      );
      await refreshOrganizationRegistry();
      return null;
    } catch (error) {
      return _accountActionError(error, 'Representative was not assigned.');
    }
  }

  Future<String?> removeOrganizationRepresentative(String profileId) async {
    final service = backend;
    if (service == null || !isInternalAdmin) {
      return 'Only an internal admin can remove representatives.';
    }
    try {
      _upsertBackendAccount(
        await service.removeOrganizationRepresentative(profileId),
      );
      await refreshOrganizationRegistry();
      return null;
    } catch (error) {
      return _accountActionError(error, 'Representative was not removed.');
    }
  }

  Future<AccountCreationResult> createOrganizationRepresentative({
    required String fullName,
    required String email,
    required String slotId,
  }) async {
    final trimmedName = fullName.trim();
    final trimmedEmail = email.trim().toLowerCase();
    if (trimmedName.length < 2) {
      return const AccountCreationResult.failure(
        'Enter the representative’s full name.',
      );
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(trimmedEmail)) {
      return const AccountCreationResult.failure(
        'Enter a valid email address.',
      );
    }
    if (backend == null || !isInternalAdmin) {
      return const AccountCreationResult.failure(
        'Only an internal admin can create representatives.',
      );
    }
    try {
      final created = await backend!.createOrganizationRepresentative(
        fullName: trimmedName,
        email: trimmedEmail,
        organizationSlotId: slotId,
      );
      _upsertBackendAccount(created.account);
      await refreshOrganizationRegistry();
      final account = _toAccount(created.account);
      log(
        action: 'created an organization representative for',
        target: account.organizationLabel,
        kind: AuditKind.account,
        diff: ['Temporary credentials generated and shown once'],
      );
      showToast(
        ToastMessage('Representative account created for $trimmedName.'),
      );
      return AccountCreationResult.success(
        AccountCredentials(
          title: 'organization representative',
          fullName: trimmedName,
          organization: account.organizationLabel,
          email: trimmedEmail,
          temporaryPassword: created.temporaryPassword,
        ),
      );
    } catch (error) {
      return AccountCreationResult.failure(
        _accountActionError(error, 'Representative wasn’t created.'),
      );
    }
  }

  Future<AccountCreationResult> resetOrganizationRepresentativePassword(
    Account account,
  ) async {
    if (backend == null || !isInternalAdmin) {
      return const AccountCreationResult.failure(
        'Only an internal admin can reset representative passwords.',
      );
    }
    if (!account.isOrganizationRepresentative) {
      return const AccountCreationResult.failure(
        'Choose an organization representative account.',
      );
    }
    try {
      final reset = await backend!.resetOrganizationRepresentativePassword(
        account.id,
      );
      _upsertBackendAccount(reset.account);
      showToast(
        ToastMessage('Temporary password generated for ${account.name}.'),
      );
      return AccountCreationResult.success(
        AccountCredentials(
          title: 'organization representative',
          fullName: account.name,
          organization: account.organizationLabel,
          email: account.email,
          temporaryPassword: reset.temporaryPassword,
        ),
      );
    } catch (error) {
      return AccountCreationResult.failure(
        _accountActionError(error, 'Temporary password was not generated.'),
      );
    }
  }

  Future<String?> transferOrganizationRepresentative({
    required String currentProfileId,
    required String replacementProfileId,
    required String slotId,
  }) async {
    final service = backend;
    if (service == null || !isInternalAdmin) {
      return 'Only an internal admin can transfer representatives.';
    }
    try {
      _upsertBackendAccount(
        await service.transferOrganizationRepresentative(
          currentProfileId: currentProfileId,
          replacementProfileId: replacementProfileId,
          slotId: slotId,
        ),
      );
      await refreshAccounts();
      await refreshOrganizationRegistry();
      return null;
    } catch (error) {
      return _accountActionError(error, 'Representative was not transferred.');
    }
  }

  Future<String?> convertLegacyAccountToExternalGuest({
    required String profileId,
    required String reason,
  }) async {
    final service = backend;
    if (service == null || !isInternalAdmin) {
      return 'Only an internal admin can convert legacy accounts.';
    }
    if (reason.trim().isEmpty) return 'Enter a reason for this conversion.';
    try {
      _upsertBackendAccount(
        await service.convertLegacyAccountToExternalGuest(
          profileId: profileId,
          reason: reason.trim(),
        ),
      );
      showToast(const ToastMessage('Account converted to external guest.'));
      return null;
    } catch (error) {
      return _accountActionError(error, 'Account was not converted.');
    }
  }

  static String _accountDate(DateTime? value) {
    if (value == null) return '—';
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

  static String _relativeAccountTime(DateTime? value, {required String never}) {
    if (value == null) return never;
    final difference = DateTime.now().difference(value);
    if (difference.inMinutes < 2) return 'Now';
    if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
    if (difference.inHours < 24) return '${difference.inHours} hours ago';
    if (difference.inDays == 1) return 'Yesterday';
    if (difference.inDays < 30) return '${difference.inDays} days ago';
    return _accountDate(value);
  }

  static String _accountError(Object error) {
    if (error is! AccountManagementException) {
      final raw = '$error'.toLowerCase();
      if (raw.contains('duplicate key') ||
          raw.contains('already exists') ||
          raw.contains('unique constraint')) {
        return 'An organization with this name already exists under the selected parent.';
      }
      return friendlyBackendMessage(
        '$error',
        fallback:
            'SmartReserve could not complete this account action. Try again.',
      );
    }
    final reference = error.requestId == null
        ? ''
        : ' If this continues, give support reference ${error.requestId}.';
    return switch (error.code) {
      'network' => 'Check your connection and try the account action again.',
      'unauthorized' =>
        'Your session expired. Sign in again before retrying this action.',
      'forbidden' =>
        'Your account no longer has permission to manage accounts.',
      'not_found' =>
        'This account no longer exists. Close this view and refresh the account list.',
      'rate_limited' =>
        'Too many requests were sent. Wait a moment, then try again.',
      'invalid_response' =>
        'SmartReserve received an invalid account response. Try again.',
      'server_error' =>
        'SmartReserve could not complete this account action. Try again.$reference',
      'guardrail' ||
      'conflict' ||
      'email_exists' ||
      'invite_not_pending' ||
      'invite_pending' ||
      'invalid_request' ||
      'invalid_role' ||
      'invalid_lift_date' ||
      'reason_required' => error.message,
      _ => 'SmartReserve could not complete this account action. Try again.',
    };
  }

  String _accountActionError(Object error, String toastText) {
    final detail = _accountError(error);
    showToast(
      ToastMessage(toastText, tone: AdvisoryTone.block),
      duration: const Duration(seconds: 6),
    );
    return detail;
  }

  String? facilitiesError;

  Future<void> refreshFacilities() async {
    final service = backend;
    if (service == null || sessionProfile == null) return;
    facilitiesLoading = true;
    facilitiesError = null;
    notifyListeners();
    try {
      _applyFacilityRows(await service.facilities());
    } catch (error) {
      facilitiesError = 'Facilities could not be loaded: $error';
      facilitiesLoading = false;
      notifyListeners();
    }
  }

  void _applyFacilityRows(List<BackendFacility> rows) {
    final service = backend;
    if (service == null) return;
    facilities = [
      for (final row in rows) row.toFacility(service.facilityPhotoUrl),
    ];
    if (userCalendarFacilityFilter != 'All facilities' &&
        !userCalendarFacilities.contains(userCalendarFacilityFilter)) {
      userCalendarFacilityFilter = 'All facilities';
    }
    facilitiesLoading = false;
    facilitiesError = null;
    notifyListeners();
  }

  VerificationSubmission _toVerification(BackendVerification row) =>
      VerificationSubmission(
        id: row.id,
        name: row.name,
        email: row.email,
        kind: switch (row.claimType) {
          'faculty' => 'Faculty',
          'staff' => 'University staff',
          _ => 'Student',
        },
        idNumber: row.campusId,
        unit: row.unit,
        document: row.documentPath == null
            ? 'Deleted after final decision'
            : row.documentName,
        submitted: row.submittedAt.toLocal().toString().substring(0, 16),
        registryMatch: true,
        nameMatch: true,
        alreadyClaimed: false,
        legible: true,
        decision: switch (row.status) {
          'approved' => VerificationDecision.approved,
          'changes_requested' => VerificationDecision.changesRequested,
          'rejected' => VerificationDecision.rejected,
          _ => VerificationDecision.pending,
        },
        decidedAt: row.decidedAt?.toLocal().toString().substring(0, 16),
        reason: row.reason,
        fromOnboarding: row.userId == sessionProfile?.id,
        userId: row.userId,
        documentPath: row.documentPath,
      );

  Future<void> signOut() async {
    Object? signOutError;
    try {
      await backend?.signOut();
    } catch (error, stackTrace) {
      signOutError = error;
      debugPrint('SmartReserve sign-out failure: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      await applyBackendProfile(null);
    }
    if (signOutError != null) {
      showToast(
        const ToastMessage(
          'You are signed out on this device, but the server could not confirm it.',
        ),
      );
    }
  }

  Account get currentAdmin {
    final profile = sessionProfile;
    if (profile?.isAdmin ?? false) {
      return Account(
        id: profile!.id,
        name: profile.fullName,
        email: profile.email,
        role: profile.isInternalAdmin
            ? AccountRole.internalAdmin
            : AccountRole.externalAdmin,
        unit: profile.unit ?? '',
        idNumber: profile.campusId ?? '',
        verification: VerificationState.verified,
        status: AccountStatus.active,
        reservations: 0,
        lastActive: 'Now',
        joined: 'Now',
        noShows: 0,
        isSelf: true,
      );
    }
    return accounts.firstWhere((a) => a.isSelf, orElse: () => accounts.last);
  }

  bool facilitiesLoading = false;

  int get pendingRequests =>
      requests.where((r) => r.status == RequestStatus.pending).length;

  int get pendingVerifications =>
      verifications.where((v) => v.isPending).length;

  int get mappedCount => facilities.where((f) => f.coords != null).length;

  int get catalogueTotal => facilities.length;

  void showToast(ToastMessage message, {Duration? duration}) =>
      toasts.show(message, duration: duration);

  @override
  void dispose() {
    toasts.dispose();
    _cancelAllRiskSummaryPolls();
    _verificationSubscription?.cancel();
    _facilitySubscription?.cancel();
    _accountSubscription?.cancel();
    _reservationSubscription?.cancel();
    _notificationSubscription?.cancel();
    _loyaltySubscription?.cancel();
    _feedbackSentimentSubscription?.cancel();
    super.dispose();
  }

  void log({
    required String action,
    required String target,
    required AuditKind kind,
    required List<String> diff,
    String reason = '',
    bool material = true,
    bool revertable = false,
    String? recordId,
  }) {
    audit = [
      AuditEntry.now(
        actor: currentAdmin.name,
        actorRole: currentAdmin.role.label,
        action: action,
        target: target,
        kind: kind,
        diff: diff,
        reason: reason,
        material: material,
        revertable: revertable,
        recordId: recordId,
      ),
      ...audit,
    ];
  }

  List<AuditEntry> facilityActivity(Facility facility) => [
    for (final entry in audit)
      if (entry.recordId == facility.id ||
          (entry.recordId == null &&
              entry.kind == AuditKind.facility &&
              entry.target == facility.name))
        entry,
  ];

  List<AuditEntry> requestActivity(String requestId) => [
    for (final entry in audit)
      if (entry.recordId == requestId) entry,
  ];

  Facility? facilityNamed(String name) {
    for (final f in facilities) {
      if (f.name == name) return f;
    }
    return null;
  }

  List<Facility> get browsableFacilities => [
    for (final f in facilities)
      if (f.publicListing && f.state != FacilityState.draft) f,
  ];

  List<Facility> get bookableFacilities => [
    for (final f in facilities)
      if (f.publicListing &&
          f.state == FacilityState.active &&
          (isAdmin || f.bookableForCurrentUser))
        f,
  ];

  List<Facility> searchFacilities({
    String query = '',
    String category = 'All categories',
    int minCapacity = 0,
    Set<String> amenities = const {},
  }) {
    return _filterFacilities(
      bookableFacilities,
      query: query,
      category: category,
      minCapacity: minCapacity,
      amenities: amenities,
    );
  }

  List<Facility> searchBrowsableFacilities({
    String query = '',
    String category = 'All categories',
    int minCapacity = 0,
    Set<String> amenities = const {},
  }) => _filterFacilities(
    browsableFacilities,
    query: query,
    category: category,
    minCapacity: minCapacity,
    amenities: amenities,
  );

  static List<Facility> _filterFacilities(
    Iterable<Facility> source, {
    required String query,
    required String category,
    required int minCapacity,
    required Set<String> amenities,
  }) {
    final normalizedQuery = query.trim().toLowerCase();
    return [
      for (final facility in source)
        if ((category == 'All categories' || facility.category == category) &&
            facility.capacity >= minCapacity &&
            amenities.every(facility.amenities.contains) &&
            (normalizedQuery.isEmpty ||
                facility.name.toLowerCase().contains(normalizedQuery) ||
                facility.room.toLowerCase().contains(normalizedQuery) ||
                facility.building.toLowerCase().contains(normalizedQuery) ||
                facility.category.toLowerCase().contains(normalizedQuery) ||
                facility.amenities.any(
                  (amenity) => amenity.toLowerCase().contains(normalizedQuery),
                )))
          facility,
    ];
  }

  bool reservationsLoading = false;
  String? reservationsError;
  String? notificationsError;
  final Set<String> reservationActionsPending = {};

  int get unreadNotifications =>
      notifications.where((item) => item.unread).length;

  Future<void> refreshReservations() async {
    final service = backend;
    if (service == null || !hasSession) return;
    reservationsLoading = true;
    reservationsError = null;
    notifyListeners();
    try {
      _applyReservationRows(await service.reservations());
    } catch (error) {
      reservationsError = 'Reservations could not load: $error';
      reservationsLoading = false;
      notifyListeners();
    }
  }

  void _applyReservationRows(List<BackendReservation> rows) {
    _backendReservations
      ..clear()
      ..addEntries(rows.map((row) => MapEntry(row.id, row)));
    requests = rows.map(_toReservationRequest).toList();
    bookings = [
      for (final row in rows)
        for (final occurrence in row.occurrences)
          if (occurrence.bookingState == 'booked')
            Booking(
              id: occurrence.id,
              facility: row.facilityName,
              facilityId: row.facilityId,
              startsAt: campusWallTime(occurrence.startsAt),
              endsAt: campusWallTime(occurrence.endsAt),
              label: row.purpose.split('.').first,
              requester: row.requesterName,
              sourceRequestId: row.id,
            ),
    ];
    if (calendarFacilityFilter != 'All facilities' &&
        !calendarFacilities.contains(calendarFacilityFilter)) {
      calendarFacilityFilter = 'All facilities';
    }
    if (userCalendarFacilityFilter != 'All facilities' &&
        !userCalendarFacilities.contains(userCalendarFacilityFilter)) {
      userCalendarFacilityFilter = 'All facilities';
    }
    final nonReservation = audit
        .where((entry) => entry.kind != AuditKind.reservation)
        .toList();
    final reservationAudit = <AuditEntry>[
      for (final row in rows)
        for (final event in row.events)
          AuditEntry(
            id: event.id,
            actor: event.actorName,
            actorRole: event.actorRole,
            action: event.action,
            target: '${row.purpose.split('.').first} — ${row.requesterName}',
            kind: AuditKind.reservation,
            when: _relative(event.createdAt),
            absolute: formatStamp(event.createdAt.toLocal()),
            material: event.material,
            diff: [if (event.details.isNotEmpty) event.details.toString()],
            reason: event.reason ?? '',
            recordId: row.id,
            createdAt: event.createdAt.toLocal(),
            changes: humanizeAuditPayload(
              entityType: 'reservation',
              action: event.action,
              details: event.details,
            ),
          ),
    ]..sort((a, b) => b.createdAt!.compareTo(a.createdAt!));
    audit = [...reservationAudit, ...nonReservation];
    reservationsLoading = false;
    reservationsError = null;
    if (selectedRequestId != null &&
        !requests.any((request) => request.id == selectedRequestId)) {
      selectedRequestId = null;
    }
    notifyListeners();
  }

  ReservationRequest _toReservationRequest(BackendReservation row) {
    final occurrences = [
      for (final occurrence in row.occurrences)
        ReservationOccurrence(
          id: occurrence.id,
          startsAt: campusWallTime(occurrence.startsAt),
          endsAt: campusWallTime(occurrence.endsAt),
          bookingState: occurrence.bookingState,
          stage: switch (occurrence.lifecycleStage) {
            'checked_in' => BookingStage.checkedIn,
            'completed' => BookingStage.completed,
            'no_show' => BookingStage.noShow,
            _ => BookingStage.booked,
          },
          proposedStartsAt: occurrence.proposedStartsAt == null
              ? null
              : campusWallTime(occurrence.proposedStartsAt!),
          proposedEndsAt: occurrence.proposedEndsAt == null
              ? null
              : campusWallTime(occurrence.proposedEndsAt!),
          reason: occurrence.exceptionReason,
          attendanceMarkedAt: occurrence.attendanceMarkedAt,
          attendanceMarkedBy: occurrence.attendanceMarkedBy,
          attendanceReason: occurrence.attendanceReason,
          cancelledAt: occurrence.cancelledAt,
          cancelledBy: occurrence.cancelledBy,
          cancellationReason: occurrence.cancellationReason,
        ),
    ];
    final first = occurrences.isEmpty
        ? DateTime.now()
        : occurrences.first.startsAt;
    return ReservationRequest(
      id: row.id,
      requesterId: row.requesterId,
      facilityId: row.facilityId,
      facility: row.facilityName,
      building: row.facilityBuilding,
      room: row.facilityRoom,
      capacity: row.facilityCapacity,
      requester: row.requesterName,
      role: row.requesterRole,
      org: row.requesterUnit,
      purpose: row.purpose,
      date: formatCampusDate(first),
      slotDay: dayOnly(first),
      start: _clock(first),
      end: _clock(occurrences.isEmpty ? first : occurrences.first.endsAt),
      heads: row.headcount,
      submitted: _relative(row.createdAt),
      urgent: first.difference(campusNow()).inHours <= 48,
      attachments: row.attachments.length,
      noShows: 0,
      status: RequestStatus.fromRaw(row.status),
      recurring: occurrences.length > 1
          ? 'Weekly · ${occurrences.length} occurrences'
          : null,
      decidedBy: row.decidedByName,
      decidedAt: row.decidedAt == null ? null : _relative(row.decidedAt!),
      reason: row.decisionReason,
      heldForVerification: row.heldForVerification,
      stage: occurrences.isEmpty
          ? BookingStage.booked
          : occurrences.first.stage,
      seriesExceptions: [
        for (final occurrence in occurrences)
          if (occurrence.needsNewTime) formatCampusDate(occurrence.startsAt),
      ],
      version: row.version,
      paymentAmountCentavos: row.paymentAmountCentavos,
      paymentStatus: PaymentTrackingStatus.fromRaw(row.paymentStatus),
      occurrences: occurrences,
      files: [
        for (final file in row.attachments)
          ReservationFile(
            id: file.id,
            name: file.fileName,
            mimeType: file.mimeType,
            byteSize: file.byteSize,
            storagePath: file.storagePath,
          ),
      ],
      amenities: row.amenities,
      adminLane: row.adminLane,
      lifecycleStatus: ReservationLifecycleStatus.fromRaw(
        row.reservationStatus,
      ),
      pricingAudience: row.pricingAudience,
      facilityAmountCentavos: row.facilityAmountCentavos,
      amenityAmountCentavos: row.amenityAmountCentavos,
      discountAmountCentavos: row.discountAmountCentavos,
      totalAmountCentavos: row.totalAmountCentavos,
      requiredDownPaymentCentavos: row.requiredDownPaymentCentavos,
      downPaymentPercent: row.downPaymentPercent,
      paymentExemption: row.paymentExemption,
      paymentDueAt: row.paymentDueAt,
      balanceDueAt: row.balanceDueAt,
      legacyFinancialState: row.legacyFinancialState,
      paymentTransactions: row.payments,
      paymentMethod: row.paymentMethod,
      permit: row.permit,
      signatureRequestId: row.signatureRequestId,
      signatureRequestStatus: row.signatureRequestStatus,
      priceLines: [
        for (final line in row.priceLines)
          PriceSnapshotLine(
            type: line.type,
            label: line.label,
            quantity: line.quantity,
            unitAmountCentavos: line.unitAmountCentavos,
            totalCentavos: line.lineTotalCentavos,
          ),
      ],
      acceptedTerms: row.acceptedTerms,
      feedbackRating: row.feedback?.rating,
      feedbackComment: row.feedback?.comment ?? '',
      feedbackAt: row.feedback?.createdAt,
      useAssessments: [
        for (final assessment in row.useAssessments)
          ReservationUseAssessment(
            id: assessment.id,
            requestId: assessment.requestId,
            occurrenceId: assessment.occurrenceId,
            facilityId: assessment.facilityId,
            requesterId: assessment.requesterId,
            adminId: assessment.adminId,
            cleanlinessRating: assessment.cleanlinessRating,
            equipmentConditionRating: assessment.equipmentConditionRating,
            leftUnclean: assessment.leftUnclean,
            equipmentDamaged: assessment.equipmentDamaged,
            comment: assessment.comment,
            revision: assessment.revision,
            createdAt: assessment.createdAt,
            updatedAt: assessment.updatedAt,
            files: [
              for (final file in assessment.files)
                ReservationUseAssessmentFile(
                  id: file.id,
                  assessmentId: file.assessmentId,
                  storagePath: file.storagePath,
                  fileName: file.fileName,
                  mimeType: file.mimeType,
                  byteSize: file.byteSize,
                ),
            ],
          ),
      ],
    );
  }

  static String _clock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  static String _relative(DateTime value) {
    final difference = DateTime.now().difference(value.toLocal());
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return '${difference.inHours} hours ago';
    return '${difference.inDays} days ago';
  }

  Future<void> refreshNotifications() async {
    final service = backend;
    if (service == null || !hasSession) return;
    try {
      _applyNotifications(await service.notifications());
      notificationPreferences = await service.notificationPreferences();
      notifyListeners();
    } catch (error) {
      notificationsError = 'Notifications could not load: $error';
      notifyListeners();
    }
  }

  void setNotificationPreference(String key, bool value) {
    notificationPreferences = {...notificationPreferences, key: value};
    notifyListeners();
    final service = backend;
    if (service != null && hasSession) {
      unawaited(
        service.saveNotificationPreferences(notificationPreferences).catchError(
          (Object error) {
            showToast(
              ToastMessage(
                'Notification preference could not be saved: $error',
                tone: AdvisoryTone.block,
              ),
            );
          },
        ),
      );
    }
  }

  void _applyNotifications(List<BackendNotification> rows) {
    notifications = rows;
    notificationsError = null;
    notifyListeners();
  }

  Future<void> openNotification(BackendNotification notification) async {
    final service = backend;
    if (notification.unread && service != null) {
      await service.markNotificationRead(notification.id);
      await refreshNotifications();
    }
    if (notification.kind == 'feedback_low_rating' && isAdmin) {
      goTo(AppView.feedback);
      return;
    }
    if (notification.kind.startsWith('anomaly_') && isAdmin) {
      goTo(AppView.anomalies);
      final anomalyId = notification.anomalyId;
      if (anomalyId != null) selectAnomaly(anomalyId);
      return;
    }
    if (notification.kind.startsWith('loyalty_') && !isAdmin) {
      pendingLoyaltyOpen = true;
      goTo(AppView.userApp);
      notifyListeners();
      return;
    }
    final requestId = notification.requestId;
    if (requestId == null) return;
    if (isAdmin) {
      view = AppView.reservations;
      final request = requestById(requestId);
      final previous = selectedRequestId;
      if (request != null) {
        requestTab = request.status;
        selectedRequestId = request.id;
      }
      notifyListeners();
      _syncSelectedRequestRiskSummary(previous, selectedRequestId);
    } else {
      goTo(AppView.userApp);
    }
  }

  Future<Facility> persistFacility(
    FacilityDraft draft, {
    String? editingId,
  }) async {
    final service = backend;
    if (service == null || !isAdmin) {
      if (service != null) {
        throw StateError(
          'Administrator access is required to edit facilities.',
        );
      }
      return saveFromDraft(draft, editingId: editingId);
    }
    if (editingId != null) {
      final existing = facilities.where((item) => item.id == editingId);
      if (existing.isEmpty || !existing.first.canManage) {
        throw StateError('Active administrator access required.');
      }
    }

    final row = await service.saveFacility(draft, editingId: editingId);
    final saved = row.toFacility(service.facilityPhotoUrl);
    final previous = editingId == null
        ? null
        : facilities.cast<Facility?>().firstWhere(
            (facility) => facility?.id == editingId,
            orElse: () => null,
          );
    facilities = [
      saved,
      for (final facility in facilities)
        if (facility.id != saved.id) facility,
    ];
    log(
      action: previous == null ? 'created the facility' : 'edited',
      target: saved.name,
      kind: AuditKind.facility,
      diff: [
        '${saved.whereLine} · ${saved.capacity} seats',
        '${saved.photoCount} photo${saved.photoCount == 1 ? '' : 's'} saved',
      ],
      recordId: saved.id,
    );
    notifyListeners();
    return saved;
  }

  Facility saveFromDraft(FacilityDraft draft, {String? editingId}) {
    final existing = editingId == null
        ? null
        : facilities.cast<Facility?>().firstWhere(
            (f) => f?.id == editingId,
            orElse: () => null,
          );

    final pinConfidence = draft.pin == null
        ? PinConfidence.none
        : (draft.confirmedOutside || !inPolygon(draft.pin!, campus.boundary)
              ? PinConfidence.needsCheck
              : PinConfidence.verified);

    final state = draft.confirmedOutside
        ? FacilityState.underReview
        : FacilityState.fromLabel(draft.status.label);

    if (existing == null) {
      final created = Facility(
        id: 'f-${DateTime.now().microsecondsSinceEpoch}',
        name: draft.name.trim(),
        room: draft.room.trim(),
        building: draft.building,
        category: draft.category,
        capacity: draft.capacitySeats ?? 0,
        pinConfidence: pinConfidence,
        state: state,
        floor: draft.floor,
        coords: draft.pin,
        accuracy: draft.accuracy,
        description: draft.description.trim(),
        amenities: List.of(draft.amenities),
        hours: draft.hoursLine,
        days: draft.daysLine,
        approvalRequired: draft.requiresApproval,
        maxDuration: draft.maxDuration,
        advance: draft.advance,
        buffer: draft.buffer,
        publicListing: draft.publicListing,
        campusName: draft.campusName,
        updated: '${_today()} · ${currentAdmin.name}',
        bookings: 0,
        photoCount: draft.photos.length,
        photos: List.of(draft.photos),
        confirmedOutside: draft.confirmedOutside,
        geoBuilding: draft.geoBuilding,
        street: draft.street,
        barangay: draft.barangay,
        municipality: draft.municipality,
        province: draft.province,
        region: draft.region,
        country: draft.country,
        geoEdited: draft.geoEdited.toList(),
      );
      facilities = [created, ...facilities];
      log(
        action: 'created the facility',
        target: created.name,
        kind: AuditKind.facility,
        diff: [
          '${created.whereLine} · ${created.capacity} seats',
          if (created.coords != null)
            'Pinned at ${formatCoords(created.coords!)} · ±'
                '${created.accuracy ?? 0} m',
        ],
        reason: draft.confirmedOutside
            ? 'Pin kept outside the campus boundary and flagged for review.'
            : '',
        recordId: created.id,
      );
      notifyListeners();
      return created;
    }

    final diff = <String>[];
    void change(String label, Object? before, Object? after) {
      if ('$before' != '$after') diff.add('$label $before  →  $after');
    }

    change('Name', existing.name, draft.name.trim());
    change('Capacity', existing.capacity, draft.capacitySeats ?? 0);
    change('Category', existing.category, draft.category);
    change('Building', existing.building, draft.building);
    change('Status', existing.state.label, state.label);
    if (existing.coords != draft.pin && draft.pin != null) {
      final movedFrom = existing.coords;
      diff.add(
        movedFrom == null
            ? 'Pin set at ${formatCoords(draft.pin!)}'
            : '${formatCoords(movedFrom)}  →  ${formatCoords(draft.pin!)}',
      );
      if (movedFrom != null) {
        final metres = haversine(movedFrom, draft.pin!);
        diff.add(
          'Moved ${formatMetres(metres)} '
          '${compassFrom(movedFrom, draft.pin!)} · accuracy ±'
          '${draft.accuracy ?? 0} m',
        );
      }
    }

    existing
      ..name = draft.name.trim()
      ..room = draft.room.trim()
      ..building = draft.building
      ..category = draft.category
      ..capacity = draft.capacitySeats ?? 0
      ..pinConfidence = pinConfidence
      ..state = state
      ..floor = draft.floor
      ..coords = draft.pin
      ..accuracy = draft.accuracy
      ..description = draft.description.trim()
      ..amenities = List.of(draft.amenities)
      ..hours = draft.hoursLine
      ..days = draft.daysLine
      ..approvalRequired = draft.requiresApproval
      ..maxDuration = draft.maxDuration
      ..advance = draft.advance
      ..buffer = draft.buffer
      ..publicListing = draft.publicListing
      ..photoCount = draft.photos.length
      ..photos = List.of(draft.photos)
      ..confirmedOutside = draft.confirmedOutside
      ..geoBuilding = draft.geoBuilding
      ..street = draft.street
      ..barangay = draft.barangay
      ..municipality = draft.municipality
      ..province = draft.province
      ..region = draft.region
      ..country = draft.country
      ..geoEdited = draft.geoEdited.toList()
      ..updated = '${_today()} · ${currentAdmin.name}';

    if (diff.isNotEmpty) {
      log(
        action: 'edited',
        target: existing.name,
        kind: AuditKind.facility,
        diff: diff,
        revertable: true,
        recordId: existing.id,
      );
    }
    notifyListeners();
    return existing;
  }

  final Set<String> archivingFacilityIds = {};

  Future<void> deleteFacility(Facility facility, {String reason = ''}) async {
    final service = backend;
    if (service != null && (!isAdmin || !facility.canManage)) {
      showToast(
        const ToastMessage(
          'You are not assigned to archive this facility.',
          tone: AdvisoryTone.block,
        ),
      );
      return;
    }
    if (service != null && isAdmin && facility.canManage) {
      if (!archivingFacilityIds.add(facility.id)) return;
      notifyListeners();
      try {
        await service.archiveFacility(facility.id);
      } catch (error) {
        showToast(
          ToastMessage(
            'Facility could not be archived: $error',
            tone: AdvisoryTone.block,
          ),
        );
        return;
      } finally {
        archivingFacilityIds.remove(facility.id);
        notifyListeners();
      }
    }
    facilities = facilities.where((f) => f.id != facility.id).toList();
    log(
      action: 'archived the facility',
      target: facility.name,
      kind: AuditKind.facility,
      diff: [
        '${facility.whereLine} · ${facility.bookings} bookings on record',
        'Removed from the catalogue',
      ],
      reason: reason,
      revertable: true,
      recordId: facility.id,
    );
    notifyListeners();
    toasts.show(
      ToastMessage.success(
        '${facility.name} archived.',
        action: ToastAction(
          label: 'Undo',
          onPressed: () => unawaited(_restoreFacility(facility)),
        ),
      ),
    );
  }

  Future<void> _restoreFacility(Facility facility) async {
    final service = backend;
    try {
      if (service != null && isAdmin && facility.canManage) {
        await service.restoreFacility(facility.id);
      }
      facilities = [
        facility,
        for (final current in facilities)
          if (current.id != facility.id) current,
      ];
      log(
        action: 'restored the facility',
        target: facility.name,
        kind: AuditKind.facility,
        diff: ['Archived  →  Active'],
        recordId: facility.id,
      );
      notifyListeners();
    } catch (error) {
      showToast(
        ToastMessage(
          'Facility could not be restored: $error',
          tone: AdvisoryTone.block,
        ),
      );
    }
  }

  RequestStatus requestTab = RequestStatus.pending;
  String? selectedRequestId = 'r1';
  final Set<String> selectedRequestIds = {};

  String? _requestAnchorId;

  List<String> get scheduleFacilities {
    final names = <String>{
      for (final f in facilities) f.name,
      for (final b in bookings) b.facility,
      for (final r in requests) r.facility,
    }.toList()..sort();
    return names;
  }

  late DateTime calendarAnchor;
  DateTime get calendarToday => _useDemoData ? campusToday : campusNow();
  CalendarViewMode calendarViewMode = CalendarViewMode.month;
  String calendarFacilityFilter = 'All facilities';
  String calendarQuery = '';
  final Set<CalendarEventState> calendarStates = {
    ...CalendarEventState.defaultVisible,
  };
  String? selectedCalendarEventId;

  late DateTime userCalendarAnchor;
  CalendarViewMode userCalendarViewMode = CalendarViewMode.month;
  String userCalendarFacilityFilter = 'All facilities';
  bool userCalendarLoading = false;
  String? userCalendarError;
  List<PublicCalendarSlot> userCalendarSlots = [];
  int _userCalendarRequestId = 0;

  List<String> get calendarFacilities => [
    'All facilities',
    ...scheduleFacilities,
  ];

  List<CalendarEvent> get calendarEvents {
    final events = <CalendarEvent>[];
    final requestOccurrenceIds = <String>{};

    for (final request in requests) {
      if (request.occurrences.isEmpty) {
        final date = parseCampusDate(request.date);
        if (date == null) continue;
        final startsAt = _dateAtClock(date, request.start);
        final endsAt = _dateAtClock(date, request.end);
        events.add(
          CalendarEvent(
            id: request.id,
            requestId: request.id,
            startsAt: startsAt,
            endsAt: endsAt.isAfter(startsAt)
                ? endsAt
                : endsAt.add(const Duration(days: 1)),
            facility: request.facility,
            building: request.building,
            room: request.room,
            requester: request.requester,
            organization: request.org,
            purpose: request.purpose,
            headcount: request.heads,
            state: _calendarStateFor(request),
            lifecycle: request.stage,
            recurrenceLabel: request.recurring,
          ),
        );
        continue;
      }

      for (final occurrence in request.occurrences) {
        requestOccurrenceIds.add(occurrence.id);
        events.add(
          CalendarEvent(
            id: '${request.id}:${occurrence.id}',
            requestId: request.id,
            occurrenceId: occurrence.id,
            startsAt: occurrence.startsAt,
            endsAt: occurrence.endsAt,
            facility: request.facility,
            building: request.building,
            room: request.room,
            requester: request.requester,
            organization: request.org,
            purpose: request.purpose,
            headcount: request.heads,
            state: _calendarStateFor(request, occurrence),
            lifecycle: occurrence.stage,
            recurrenceLabel: request.recurring,
          ),
        );
      }
    }

    for (final booking in bookings) {
      if (booking.sourceRequestId != null &&
          requests.any((request) => request.id == booking.sourceRequestId)) {
        continue;
      }
      final date = parseCampusDate(booking.date);
      if (date == null || requestOccurrenceIds.contains(booking.id)) continue;
      final startsAt = _dateAtClock(date, booking.start);
      final endsAt = _dateAtClock(date, booking.end);
      events.add(
        CalendarEvent(
          id: booking.id,
          requestId: booking.sourceRequestId,
          startsAt: startsAt,
          endsAt: endsAt.isAfter(startsAt)
              ? endsAt
              : endsAt.add(const Duration(days: 1)),
          facility: booking.facility,
          building: '',
          room: '',
          requester: booking.requester,
          organization: '',
          purpose: booking.label,
          headcount: 0,
          state: CalendarEventState.confirmed,
          lifecycle: BookingStage.booked,
          legacy: booking.sourceRequestId == null,
        ),
      );
    }
    events.sort((a, b) => a.startsAt.compareTo(b.startsAt));
    return events;
  }

  List<CalendarEvent> get visibleCalendarEvents {
    final query = calendarQuery.trim().toLowerCase();
    return [
      for (final event in calendarEvents)
        if ((calendarFacilityFilter == 'All facilities' ||
                event.facility == calendarFacilityFilter) &&
            calendarStates.contains(event.state) &&
            event.matchesQuery(query))
          event,
    ];
  }

  List<Facility> get publicCalendarFacilities => [
    for (final f in facilities)
      if (f.publicListing && f.state == FacilityState.active) f,
  ];

  List<String> get userCalendarFacilities => [
    'All facilities',
    ...{for (final f in publicCalendarFacilities) f.name}.toList()..sort(),
  ];

  List<CalendarEvent> get userCalendarEvents {
    final facilitiesById = {
      for (final facility in facilities) facility.id: facility,
    };
    final events = <CalendarEvent>[];
    for (final slot in userCalendarSlots) {
      final facility = facilitiesById[slot.facilityId];
      if (facility == null ||
          !facility.publicListing ||
          facility.state != FacilityState.active) {
        continue;
      }
      events.add(
        CalendarEvent(
          id: 'public:${slot.facilityId}:${slot.startsAt.toIso8601String()}:${slot.endsAt.toIso8601String()}',
          startsAt: slot.startsAt,
          endsAt: slot.endsAt,
          facility: facility.name,
          building: facility.building,
          room: facility.room,
          requester: 'Reserved',
          organization: '',
          purpose: 'Reserved',
          headcount: 0,
          state: CalendarEventState.confirmed,
          lifecycle: BookingStage.booked,
          statusLabel: 'Reserved',
          summaryLabel: 'Reserved',
          privacyMasked: true,
        ),
      );
    }
    events.sort((a, b) => a.startsAt.compareTo(b.startsAt));
    return events;
  }

  List<CalendarEvent> get visibleUserCalendarEvents => [
    for (final event in userCalendarEvents)
      if (userCalendarFacilityFilter == 'All facilities' ||
          event.facility == userCalendarFacilityFilter)
        event,
  ];

  CalendarEvent? get selectedCalendarEvent {
    final id = selectedCalendarEventId;
    if (id == null) return null;
    for (final event in calendarEvents) {
      if (event.id == id) return event;
    }
    return null;
  }

  void setCalendarViewMode(CalendarViewMode mode) {
    if (calendarViewMode == mode) return;
    calendarViewMode = mode;
    notifyListeners();
  }

  void setCalendarFacilityFilter(String facility) {
    calendarFacilityFilter = facility;
    notifyListeners();
  }

  void setCalendarQuery(String query) {
    calendarQuery = query;
    notifyListeners();
  }

  void resetCalendarFilters() {
    calendarFacilityFilter = 'All facilities';
    calendarQuery = '';
    calendarStates
      ..clear()
      ..addAll(CalendarEventState.defaultVisible);
    selectedCalendarEventId = null;
    notifyListeners();
  }

  void toggleCalendarState(CalendarEventState state) {
    if (!calendarStates.remove(state)) calendarStates.add(state);
    notifyListeners();
  }

  void navigateCalendar(int direction) {
    calendarAnchor = switch (calendarViewMode) {
      CalendarViewMode.month => DateTime(
        calendarAnchor.year,
        calendarAnchor.month + direction,
        1,
      ),
      CalendarViewMode.week => calendarAnchor.add(
        Duration(days: 7 * direction),
      ),
      CalendarViewMode.day => calendarAnchor.add(Duration(days: direction)),
    };
    selectedCalendarEventId = null;
    notifyListeners();
  }

  void goToCalendarToday() {
    calendarAnchor = calendarToday;
    selectedCalendarEventId = null;
    notifyListeners();
  }

  void selectCalendarDate(DateTime date, {CalendarViewMode? mode}) {
    calendarAnchor = DateTime(date.year, date.month, date.day);
    if (mode != null) calendarViewMode = mode;
    selectedCalendarEventId = null;
    notifyListeners();
  }

  void selectCalendarEvent(String? id) {
    selectedCalendarEventId = id;
    notifyListeners();
  }

  void openRequestFromCalendar(CalendarEvent event) {
    final id = event.requestId;
    if (id == null) return;
    final request = requestById(id);
    if (request == null) return;
    final previous = selectedRequestId;
    requestTab = request.status;
    selectedRequestId = request.id;
    selectedRequestIds.clear();
    _requestAnchorId = null;
    view = AppView.reservations;
    closeOverlays();
    notifyListeners();
    _syncSelectedRequestRiskSummary(previous, selectedRequestId);
  }

  Future<void> ensureUserCalendarLoaded() async {
    if (userCalendarSlots.isNotEmpty || userCalendarLoading) return;
    await refreshUserCalendar();
  }

  Future<void> refreshUserCalendar() async {
    final requestId = ++_userCalendarRequestId;
    userCalendarLoading = true;
    userCalendarError = null;
    notifyListeners();
    try {
      final slots = _useDemoData
          ? _localPublicCalendarSlots()
          : await _remotePublicCalendarSlots();
      if (requestId != _userCalendarRequestId) return;
      userCalendarSlots = slots;
      userCalendarError = null;
    } catch (error) {
      if (requestId != _userCalendarRequestId) return;
      userCalendarError = 'Reserved dates could not load: $error';
    } finally {
      if (requestId == _userCalendarRequestId) {
        userCalendarLoading = false;
        notifyListeners();
      }
    }
  }

  Future<List<PublicCalendarSlot>> _remotePublicCalendarSlots() async {
    final service = backend;
    if (service == null || !hasSession || isAdmin) return const [];
    if (userAccount.status != AccountStatus.active) return const [];
    final targets = _selectedPublicCalendarFacilities();
    if (targets.isEmpty) return const [];
    final (fromWall, toWall) = _calendarRange(
      userCalendarAnchor,
      userCalendarViewMode,
    );
    final slots = <PublicCalendarSlot>[];
    for (var i = 0; i < targets.length; i += 40) {
      final batch = targets
          .skip(i)
          .take(40)
          .map((facility) => facility.id)
          .toList();
      final rows = await service.publicReservationCalendar(
        facilityIds: batch,
        from: campusInstant(fromWall),
        to: campusInstant(toWall),
      );
      slots.addAll([
        for (final row in rows)
          PublicCalendarSlot(
            facilityId: row.facilityId,
            startsAt: campusWallTime(row.startsAt),
            endsAt: campusWallTime(row.endsAt),
          ),
      ]);
    }
    slots.sort((a, b) => a.startsAt.compareTo(b.startsAt));
    return slots;
  }

  List<Facility> _selectedPublicCalendarFacilities() {
    if (userCalendarFacilityFilter == 'All facilities') {
      return publicCalendarFacilities;
    }
    return [
      for (final facility in publicCalendarFacilities)
        if (facility.name == userCalendarFacilityFilter) facility,
    ];
  }

  List<PublicCalendarSlot> _localPublicCalendarSlots() {
    final targets = _selectedPublicCalendarFacilities();
    if (targets.isEmpty) return const [];
    final targetIds = {for (final facility in targets) facility.id};
    final targetNames = {for (final facility in targets) facility.name};
    final (from, to) = _calendarRange(userCalendarAnchor, userCalendarViewMode);
    final slots = <PublicCalendarSlot>[];

    for (final booking in bookings) {
      final facility = booking.facilityId == null
          ? facilityNamed(booking.facility)
          : facilities.cast<Facility?>().firstWhere(
              (item) => item?.id == booking.facilityId,
              orElse: () => null,
            );
      final facilityId = facility?.id ?? booking.facilityId;
      if (facilityId == null ||
          (!targetIds.contains(facilityId) &&
              !targetNames.contains(booking.facility))) {
        continue;
      }
      if (!booking.startsAt.isBefore(to) || !booking.endsAt.isAfter(from)) {
        continue;
      }
      slots.add(
        PublicCalendarSlot(
          facilityId: facilityId,
          startsAt: booking.startsAt,
          endsAt: booking.endsAt,
        ),
      );
    }

    for (final request in requests) {
      final facilityId = _facilityIdFor(request);
      if (facilityId == null || !targetIds.contains(facilityId)) continue;
      if (request.occurrences.isEmpty) {
        if (request.status != RequestStatus.approved) continue;
        final date = parseCampusDate(request.date);
        if (date == null) continue;
        final startsAt = _dateAtClock(date, request.start);
        final endsAt = _dateAtClock(date, request.end);
        final normalizedEnd = endsAt.isAfter(startsAt)
            ? endsAt
            : endsAt.add(const Duration(days: 1));
        if (!startsAt.isBefore(to) || !normalizedEnd.isAfter(from)) continue;
        slots.add(
          PublicCalendarSlot(
            facilityId: facilityId,
            startsAt: startsAt,
            endsAt: normalizedEnd,
          ),
        );
        continue;
      }
      for (final occurrence in request.occurrences) {
        if (occurrence.bookingState != 'held' &&
            occurrence.bookingState != 'booked') {
          continue;
        }
        if (!occurrence.startsAt.isBefore(to) ||
            !occurrence.endsAt.isAfter(from)) {
          continue;
        }
        slots.add(
          PublicCalendarSlot(
            facilityId: facilityId,
            startsAt: occurrence.startsAt,
            endsAt: occurrence.endsAt,
          ),
        );
      }
    }
    slots.sort((a, b) => a.startsAt.compareTo(b.startsAt));
    return slots;
  }

  void setUserCalendarViewMode(CalendarViewMode mode) {
    if (userCalendarViewMode == mode) return;
    userCalendarViewMode = mode;
    notifyListeners();
    unawaited(refreshUserCalendar());
  }

  void setUserCalendarFacilityFilter(String facility) {
    userCalendarFacilityFilter = facility;
    notifyListeners();
    unawaited(refreshUserCalendar());
  }

  void navigateUserCalendar(int direction) {
    userCalendarAnchor = switch (userCalendarViewMode) {
      CalendarViewMode.month => DateTime(
        userCalendarAnchor.year,
        userCalendarAnchor.month + direction,
        1,
      ),
      CalendarViewMode.week => userCalendarAnchor.add(
        Duration(days: 7 * direction),
      ),
      CalendarViewMode.day => userCalendarAnchor.add(Duration(days: direction)),
    };
    notifyListeners();
    unawaited(refreshUserCalendar());
  }

  void goToUserCalendarToday() {
    userCalendarAnchor = calendarToday;
    notifyListeners();
    unawaited(refreshUserCalendar());
  }

  void selectUserCalendarDate(DateTime date, {CalendarViewMode? mode}) {
    userCalendarAnchor = DateTime(date.year, date.month, date.day);
    if (mode != null) userCalendarViewMode = mode;
    notifyListeners();
    unawaited(refreshUserCalendar());
  }

  static (DateTime, DateTime) _calendarRange(
    DateTime anchor,
    CalendarViewMode mode,
  ) => switch (mode) {
    CalendarViewMode.month => (
      DateTime(anchor.year, anchor.month),
      DateTime(anchor.year, anchor.month + 1),
    ),
    CalendarViewMode.week => (
      _weekStartDate(anchor),
      _weekStartDate(anchor).add(const Duration(days: 7)),
    ),
    CalendarViewMode.day => (
      DateTime(anchor.year, anchor.month, anchor.day),
      DateTime(anchor.year, anchor.month, anchor.day + 1),
    ),
  };

  static DateTime _weekStartDate(DateTime day) {
    final date = DateTime(day.year, day.month, day.day);
    return date.subtract(Duration(days: date.weekday - 1));
  }

  static DateTime _dateAtClock(DateTime date, String clock) {
    final value = parseClock(clock);
    final hour = value.floor();
    final minute = ((value - hour) * 60).round();
    return DateTime(date.year, date.month, date.day, hour, minute);
  }

  static CalendarEventState _calendarStateFor(
    ReservationRequest request, [
    ReservationOccurrence? occurrence,
  ]) {
    final bookingState = occurrence?.bookingState;
    return switch (bookingState) {
      'booked' => CalendarEventState.confirmed,
      'requested' => CalendarEventState.needsDecision,
      'changes_requested' || 'bumped' => CalendarEventState.changesRequested,
      'expired' => CalendarEventState.expired,
      'cancelled' when request.status == RequestStatus.declined =>
        CalendarEventState.declined,
      'cancelled' => CalendarEventState.cancelled,
      _ => switch (request.status) {
        RequestStatus.approved => CalendarEventState.confirmed,
        RequestStatus.pending => CalendarEventState.needsDecision,
        RequestStatus.changesRequested => CalendarEventState.changesRequested,
        RequestStatus.declined => CalendarEventState.declined,
        RequestStatus.cancelled => CalendarEventState.cancelled,
        RequestStatus.expired => CalendarEventState.expired,
      },
    };
  }

  List<ReservationRequest> get visibleRequests =>
      requests.where((r) => r.status == requestTab).toList();

  ReservationRequest? get selectedRequest {
    for (final r in requests) {
      if (r.id == selectedRequestId) return r;
    }
    return null;
  }

  void setRequestTab(RequestStatus tab) {
    final previous = selectedRequestId;
    requestTab = tab;
    selectedRequestIds.clear();
    _requestAnchorId = null;
    final list = visibleRequests;
    selectedRequestId = list.isEmpty ? null : list.first.id;
    notifyListeners();
    _syncSelectedRequestRiskSummary(previous, selectedRequestId);
  }

  void selectRequest(String? id) {
    final previous = selectedRequestId;
    selectedRequestId = id;
    notifyListeners();
    _syncSelectedRequestRiskSummary(previous, id);
  }

  void stepRequestSelection(int delta) {
    final list = visibleRequests;
    if (list.isEmpty) return;
    final index = list.indexWhere((r) => r.id == selectedRequestId);
    final next = (index < 0 ? 0 : index + delta).clamp(0, list.length - 1);
    final previous = selectedRequestId;
    selectedRequestId = list[next].id;
    notifyListeners();
    _syncSelectedRequestRiskSummary(previous, selectedRequestId);
  }

  void toggleRequestSelection(String id, {bool extend = false}) {
    final rows = [for (final r in visibleRequests) r.id];
    if (extend && _requestAnchorId != null) {
      selectedRequestIds.addAll(_range(rows, _requestAnchorId!, id));
      notifyListeners();
      return;
    }
    if (!selectedRequestIds.remove(id)) selectedRequestIds.add(id);
    _requestAnchorId = id;
    notifyListeners();
  }

  static List<String> _range(List<String> rows, String from, String to) {
    final a = rows.indexOf(from);
    final b = rows.indexOf(to);
    if (a < 0 || b < 0) return const [];
    return rows.sublist(a < b ? a : b, (a < b ? b : a) + 1);
  }

  void clearRequestSelection() {
    selectedRequestIds.clear();
    _requestAnchorId = null;
    notifyListeners();
  }

  void decideRequest(
    String id,
    RequestStatus outcome, {
    String reason = '',
    bool announce = true,
  }) {
    final request = requests.cast<ReservationRequest?>().firstWhere(
      (r) => r?.id == id,
      orElse: () => null,
    );
    if (request == null) return;
    if (!_useDemoData && backend != null && hasSession) {
      final action = switch (outcome) {
        RequestStatus.approved => 'approve',
        RequestStatus.declined => 'decline',
        RequestStatus.changesRequested => 'request_changes',
        RequestStatus.pending => 'reopen',
        RequestStatus.expired => 'expire',
        RequestStatus.cancelled => 'cancel',
      };
      unawaited(
        _runReservationAction(
          request,
          action,
          reason: reason,
          announce: announce,
        ),
      );
      return;
    }

    final before = request.status;
    final beforeReason = request.reason;
    request
      ..status = outcome
      ..reason = reason.isEmpty ? null : reason
      ..decidedBy = 'You'
      ..decidedAt = 'Just now';
    _syncHoldsForRequest(request);

    log(
      action: switch (outcome) {
        RequestStatus.approved => 'approved the reservation',
        RequestStatus.declined => 'declined the reservation',
        RequestStatus.changesRequested =>
          'requested changes to the reservation',
        _ => 'updated the reservation',
      },
      target: '${request.purpose.split('.').first} — ${request.org}',
      kind: AuditKind.reservation,
      diff: [
        '${before.label}  →  ${outcome.label}',
        '${request.date} · ${request.start}–${request.end} · '
            '${request.facility}',
      ],
      reason: reason,
      revertable: true,
      recordId: request.id,
    );
    notifyListeners();

    if (!announce) return;
    toasts.show(
      ToastMessage.success(
        '${outcome.label} — ${request.requester}',
        action: ToastAction(
          label: 'Undo',
          onPressed: () {
            request
              ..status = before
              ..reason = beforeReason
              ..decidedBy = null
              ..decidedAt = null;
            _syncHoldsForRequest(request);
            log(
              action: 'undid the decision on',
              target: '${request.purpose.split('.').first} — ${request.org}',
              kind: AuditKind.reservation,
              diff: ['${outcome.label}  →  ${before.label}'],
              recordId: request.id,
            );
            notifyListeners();
          },
        ),
      ),
    );
  }

  void bulkApproveRequests(Iterable<String> ids) {
    final list = ids.toList();
    if (list.isEmpty) return;
    if (!_useDemoData && backend != null && hasSession) {
      unawaited(_runBulkApprove(list));
      return;
    }
    for (final id in list) {
      decideRequest(id, RequestStatus.approved, announce: false);
    }
    selectedRequestIds.clear();
    notifyListeners();
    showToast(
      ToastMessage(
        '${list.length} request${list.length == 1 ? '' : 's'} approved.',
      ),
    );
  }

  void bumpFor(String requestId, String reason) {
    final request = requests.cast<ReservationRequest?>().firstWhere(
      (r) => r?.id == requestId,
      orElse: () => null,
    );
    if (request == null) return;
    if (!_useDemoData && backend != null && hasSession) {
      unawaited(_runReservationAction(request, 'approve_bump', reason: reason));
      return;
    }
    final bumped = holdsAgainst(
      request: request,
      bookings: bookings,
      otherRequests: requests,
    );
    final bumpedRequestIds = {
      for (final hold in bumped)
        if (hold.sourceRequestId != null) hold.sourceRequestId!,
    };
    bookings.removeWhere(
      (b) =>
          (b.sourceRequestId != null &&
              bumpedRequestIds.contains(b.sourceRequestId)) ||
          bumped.any(
            (hold) =>
                hold.sourceRequestId == null &&
                b.sourceRequestId == null &&
                b.label == hold.label &&
                b.startsAt == hold.startsAt &&
                b.endsAt == hold.endsAt,
          ),
    );
    for (final otherId in bumpedRequestIds) {
      final other = requestById(otherId);
      if (other == null) continue;
      other
        ..status = RequestStatus.changesRequested
        ..reason =
            'Bumped for a higher-priority booking in the same slot. '
            'Pick a new time and it goes straight through.'
        ..decidedBy = 'You'
        ..decidedAt = 'Just now';
      log(
        action: 'bumped by a higher-priority booking',
        target: '${other.purpose.split('.').first} — ${other.org}',
        kind: AuditKind.reservation,
        diff: ['${RequestStatus.approved.label}  →  ${other.status.label}'],
        reason: reason,
        recordId: other.id,
      );
    }
    decideRequest(requestId, RequestStatus.approved, reason: reason);
    log(
      action: 'bumped a confirmed booking for',
      target: request.facility,
      kind: AuditKind.reservation,
      diff: [
        for (final b in bumped)
          '${b.label} (${b.requester}) · ${b.start}–${b.end} · removed',
        'Both parties notified',
      ],
      reason: reason,
      revertable: true,
      recordId: request.id,
    );
    notifyListeners();
  }

  void offerAlternativeSlot(String requestId, String start, String end) {
    final request = requests.cast<ReservationRequest?>().firstWhere(
      (r) => r?.id == requestId,
      orElse: () => null,
    );
    if (request == null) return;
    if (!_useDemoData && backend != null && hasSession) {
      final occurrence = request.occurrences.isEmpty
          ? null
          : request.occurrences.first;
      if (occurrence == null) return;
      DateTime at(String value) {
        final parts = value.split(':').map(int.parse).toList();
        return DateTime(
          occurrence.startsAt.year,
          occurrence.startsAt.month,
          occurrence.startsAt.day,
          parts[0],
          parts[1],
        );
      }

      unawaited(
        _runReservationAction(
          request,
          'offer_alternative',
          reason:
              'The requested slot is unavailable. An alternative was offered.',
          payload: {
            'occurrence_id': occurrence.id,
            'starts_at': at(start).toUtc().toIso8601String(),
            'ends_at': at(end).toUtc().toIso8601String(),
          },
        ),
      );
      return;
    }
    final was = '${request.start}–${request.end}';
    request
      ..start = start
      ..end = end;
    decideRequest(
      requestId,
      RequestStatus.changesRequested,
      reason:
          'The slot you asked for is taken. $start–$end on the same day is '
          'free — accept it and the booking is confirmed.',
    );
    log(
      action: 'offered an alternative slot for',
      target: request.facility,
      kind: AuditKind.reservation,
      diff: ['$was  →  $start–$end'],
      recordId: request.id,
    );
    notifyListeners();
  }

  Future<void> _runReservationAction(
    ReservationRequest request,
    String action, {
    String reason = '',
    Map<String, dynamic> payload = const {},
    bool announce = true,
    bool reversible = true,
  }) async {
    await _runReservationActionWithResult(
      request,
      action,
      reason: reason,
      payload: payload,
      announce: announce,
      reversible: reversible,
    );
  }

  Future<bool> _runReservationActionWithResult(
    ReservationRequest request,
    String action, {
    String reason = '',
    Map<String, dynamic> payload = const {},
    bool announce = true,
    bool reversible = true,
  }) async {
    final service = backend;
    if (service == null || reservationActionsPending.contains(request.id)) {
      return false;
    }
    reservationActionsPending.add(request.id);
    notifyListeners();
    try {
      final result = await service.performReservationAction(
        ReservationActionCommand(
          requestId: request.id,
          action: action,
          expectedVersion: request.version,
          reason: reason.trim().isEmpty ? null : reason.trim(),
          payload: payload,
        ),
      );
      await refreshReservations();
      final actionLabel = _reservationActionSuccessLabel(
        action,
        requestById(request.id),
      );
      final actionId = result.actionId;
      if (reversible && actionId != null) {
        toasts.show(
          ToastMessage.success(
            '$actionLabel — ${request.requester}',
            action: ToastAction(
              label: 'Undo',
              onPressed: () => unawaited(_undoBackendReservation(actionId)),
            ),
          ),
        );
      } else if (announce) {
        toasts.show(ToastMessage.success('$actionLabel saved.'));
      }
      return true;
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      await refreshReservations();
      return false;
    } finally {
      reservationActionsPending.remove(request.id);
      notifyListeners();
    }
  }

  Future<void> _runBulkApprove(List<String> ids) async {
    final service = backend;
    if (service == null) return;
    final rows = ids
        .map((id) => _backendReservations[id])
        .whereType<BackendReservation>()
        .toList();
    if (rows.length != ids.length) {
      showToast(
        const ToastMessage(
          'The selection changed. Refresh and select the requests again.',
          tone: AdvisoryTone.block,
        ),
      );
      return;
    }
    reservationActionsPending.addAll(ids);
    notifyListeners();
    try {
      final result = await service.bulkApproveReservations(rows);
      selectedRequestIds.clear();
      await refreshReservations();
      final approvedRequests = <ReservationRequest>[];
      for (final id in ids) {
        final request = requestById(id);
        if (request != null) approvedRequests.add(request);
      }
      final successLabel = _bulkApprovalSuccessLabel(
        ids.length,
        approvedRequests,
      );
      if (result.actionIds.isNotEmpty) {
        toasts.show(
          ToastMessage.success(
            successLabel,
            action: ToastAction(
              label: 'Undo',
              onPressed: () => unawaited(
                _undoBackendReservations(result.actionIds.reversed),
              ),
            ),
          ),
        );
      } else {
        toasts.show(ToastMessage.success(successLabel));
      }
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      await refreshReservations();
    } finally {
      reservationActionsPending.removeAll(ids);
      notifyListeners();
    }
  }

  Future<void> _undoBackendReservation(String actionId) async {
    try {
      await backend?.undoReservationAction(actionId);
      await refreshReservations();
      showToast(const ToastMessage('Reservation action undone.'));
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
    }
  }

  Future<void> _undoBackendReservations(Iterable<String> actionIds) async {
    try {
      for (final actionId in actionIds) {
        await backend?.undoReservationAction(actionId);
      }
      await refreshReservations();
      showToast(const ToastMessage('Bulk approval undone.'));
    } catch (error) {
      await refreshReservations();
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
    }
  }

  static String _actionLabel(String action) => switch (action) {
    'approve' => 'Approval',
    'approve_partial' => 'Series approval',
    'approve_bump' => 'Approval and bump',
    'decline' => 'Decline',
    'request_changes' => 'Change request',
    'offer_alternative' => 'Alternative time',
    'reopen' => 'Reopen',
    'expire' => 'Expiry',
    'check_in' => 'Check-in',
    'complete' => 'Completion',
    'no_show' => 'No-show',
    'cancel' => 'Cancellation',
    'resubmit' => 'Resubmission',
    _ => 'Reservation update',
  };

  static String _reservationActionSuccessLabel(
    String action,
    ReservationRequest? request,
  ) {
    final isAwaitingPayment =
        request?.lifecycleStatus == ReservationLifecycleStatus.awaitingPayment;
    if ((action == 'approve' ||
            action == 'approve_partial' ||
            action == 'approve_bump' ||
            action == 'accept_alternative') &&
        isAwaitingPayment) {
      return 'Approved — awaiting payment';
    }
    return _actionLabel(action);
  }

  Future<bool> selfCheckInOccurrence(
    ReservationRequest request,
    ReservationOccurrence occurrence,
  ) async {
    final service = backend;
    if (service == null || !hasSession || _useDemoData) return false;
    final key = 'checkin:${occurrence.id}';
    if (reservationActionsPending.contains(key)) return false;
    reservationActionsPending.add(key);
    notifyListeners();
    try {
      await service.performReservationAction(
        ReservationActionCommand(
          requestId: request.id,
          action: 'self_check_in',
          expectedVersion: request.version,
          payload: {'occurrence_id': occurrence.id},
        ),
      );
      await refreshReservations();
      showToast(const ToastMessage('Checked in.'));
      return true;
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return false;
    } finally {
      reservationActionsPending.remove(key);
      notifyListeners();
    }
  }

  static String _bulkApprovalSuccessLabel(
    int count,
    List<ReservationRequest> requests,
  ) {
    final subject = '$count ${count == 1 ? 'reservation' : 'reservations'}';
    if (requests.length != count) {
      return '$subject approved.';
    }

    final awaitingPayment = requests
        .where(
          (request) =>
              request.lifecycleStatus ==
              ReservationLifecycleStatus.awaitingPayment,
        )
        .length;
    final confirmed = requests
        .where(
          (request) =>
              request.lifecycleStatus == ReservationLifecycleStatus.confirmed,
        )
        .length;

    if (awaitingPayment == count) {
      return '$subject approved — awaiting payment.';
    }
    if (confirmed == count) {
      return '$subject approved and confirmed.';
    }
    if (awaitingPayment > 0 && confirmed > 0) {
      return '$subject approved. Paid reservations are awaiting payment.';
    }
    return '$subject approved.';
  }

  static String _reservationError(Object error) {
    final message = '$error';
    if (message.contains('23P01') || message.toLowerCase().contains('booked')) {
      return 'That time was just booked. Refresh and choose another slot.';
    }
    if (message.contains('40001') || message.contains('changed')) {
      return 'This reservation changed in another session. It has been refreshed.';
    }
    if (message.contains('23514')) {
      return 'One of those values is out of range. Check the attendee count '
          'and times, then try again.';
    }
    return friendlyBackendMessage(message);
  }

  ReservationRequest? requestById(String id) {
    for (final r in requests) {
      if (r.id == id) return r;
    }
    return null;
  }

  void _syncHoldsForRequest(ReservationRequest request) {
    final hasHold = bookings.any((b) => b.sourceRequestId == request.id);
    if (request.status == RequestStatus.approved) {
      if (!hasHold) _bookOccurrences(request, [request.date]);
    } else if (hasHold) {
      bookings.removeWhere((b) => b.sourceRequestId == request.id);
    }
  }

  void _bookOccurrences(ReservationRequest request, List<String> dates) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    for (var i = 0; i < dates.length; i++) {
      bookings.add(
        Booking.fromLabels(
          id: 'b-$stamp-$i',
          facility: request.facility,
          facilityId: request.facilityId,
          date: dates[i],
          start: request.start,
          end: request.end,
          label: request.purpose.split('.').first,
          requester: request.requester,
          sourceRequestId: request.id,
        ),
      );
    }
  }

  void approveSeries(String id, List<String> dates) {
    final request = requestById(id);
    if (request == null) return;
    if (!_useDemoData && backend != null && hasSession) {
      unawaited(_runReservationAction(request, 'approve'));
      return;
    }
    request.seriesExceptions.clear();
    _bookOccurrences(request, dates);
    decideRequest(id, RequestStatus.approved, announce: false);
    log(
      action: 'approved the whole series for',
      target: request.facility,
      kind: AuditKind.reservation,
      diff: [
        '${dates.length} dates booked · ${request.start}–${request.end}',
        '${dates.first}  →  ${dates.last}',
      ],
      revertable: true,
      recordId: request.id,
    );
    notifyListeners();
    showToast(
      ToastMessage('${dates.length} dates booked for ${request.requester}.'),
    );
  }

  void approveSeriesWithExceptions(
    String id, {
    required List<String> booked,
    required List<String> excepted,
  }) {
    final request = requestById(id);
    if (request == null) return;
    if (!_useDemoData && backend != null && hasSession) {
      unawaited(_runReservationAction(request, 'approve_partial'));
      return;
    }
    request.seriesExceptions
      ..clear()
      ..addAll(excepted);
    _bookOccurrences(request, booked);
    decideRequest(
      id,
      RequestStatus.approved,
      reason:
          '${booked.length} of ${booked.length + excepted.length} dates are '
          'confirmed. ${excepted.join(', ')} '
          '${excepted.length == 1 ? 'is' : 'are'} already taken — pick another '
          'time for ${excepted.length == 1 ? 'it' : 'those'} and it goes '
          'straight through.',
      announce: false,
    );
    log(
      action: 'approved the series with exceptions for',
      target: request.facility,
      kind: AuditKind.reservation,
      diff: [
        '${booked.length} dates booked',
        '${excepted.length} returned: ${excepted.join(', ')}',
      ],
      revertable: true,
      recordId: request.id,
    );
    notifyListeners();
    showToast(
      ToastMessage(
        '${booked.length} dates booked · ${excepted.length} returned for a '
        'new time.',
      ),
    );
  }

  bool canExpire(ReservationRequest request) {
    if (!request.isPending) return false;
    if (!_useDemoData && request.occurrences.isNotEmpty) {
      return request.occurrences.every(
        (occurrence) => occurrence.startsAt.isBefore(campusNow()),
      );
    }
    final date = parseCampusDate(request.date);
    if (date != null && date.isBefore(campusToday)) return true;
    final match = RegExp(r'(\d+)\s*day').firstMatch(request.submitted);
    return int.parse(match?.group(1) ?? '0') >= 3;
  }

  void expireRequest(String id) {
    final request = requestById(id);
    if (request == null) return;
    if (!_useDemoData && backend != null && hasSession) {
      unawaited(_runReservationAction(request, 'expire'));
      return;
    }
    final before = request.status;
    request
      ..status = RequestStatus.expired
      ..decidedBy = 'the system'
      ..decidedAt = 'Just now';
    log(
      action: 'marked the reservation expired',
      target: '${request.purpose.split('.').first} — ${request.org}',
      kind: AuditKind.reservation,
      diff: [
        '${before.label}  →  ${RequestStatus.expired.label}',
        'No decision was needed — the date has passed',
      ],
      revertable: true,
      recordId: request.id,
    );
    notifyListeners();
    toasts.show(
      ToastMessage.success(
        'Expired — ${request.requester}',
        action: ToastAction(
          label: 'Undo',
          onPressed: () {
            request
              ..status = before
              ..decidedBy = null
              ..decidedAt = null;
            notifyListeners();
          },
        ),
      ),
    );
  }

  void advanceStage(String id, BookingStage stage) {
    final request = requestById(id);
    if (request == null) return;
    if (!_useDemoData && backend != null && hasSession) {
      final occurrence = request.occurrences.firstWhere(
        (item) => item.isBooked && item.stage != BookingStage.completed,
        orElse: () => request.occurrences.first,
      );
      final action = switch (stage) {
        BookingStage.checkedIn => 'check_in',
        BookingStage.completed => 'complete',
        BookingStage.noShow => 'no_show',
        BookingStage.booked => 'reopen',
      };
      unawaited(
        _runReservationAction(
          request,
          action,
          payload: {'occurrence_id': occurrence.id},
          reversible: false,
        ),
      );
      return;
    }
    final before = request.stage;
    request.stage = stage;
    log(
      action: switch (stage) {
        BookingStage.checkedIn => 'checked in attendees for',
        BookingStage.completed => 'closed the booking for',
        BookingStage.noShow => 'marked a no-show for',
        BookingStage.booked => 'reopened the booking for',
      },
      target: request.facility,
      kind: AuditKind.reservation,
      diff: [
        '${before.label}  →  ${stage.label}',
        if (stage == BookingStage.completed)
          'Counts toward utilisation for ${request.facility}',
      ],
      material: stage == BookingStage.completed,
      recordId: request.id,
    );
    notifyListeners();
  }

  void advanceOccurrenceStage(
    ReservationRequest request,
    ReservationOccurrence occurrence,
    BookingStage stage,
  ) {
    if (_useDemoData || backend == null) {
      advanceStage(request.id, stage);
      return;
    }
    final action = switch (stage) {
      BookingStage.checkedIn => 'check_in',
      BookingStage.completed => 'complete',
      BookingStage.noShow => 'no_show',
      BookingStage.booked => 'reopen',
    };
    unawaited(
      _runReservationAction(
        request,
        action,
        payload: {'occurrence_id': occurrence.id},
        reversible: false,
      ),
    );
  }

  VerificationDecision verificationTab = VerificationDecision.pending;
  String? selectedVerificationId = 'v1';
  final Set<String> selectedVerificationIds = {};

  List<VerificationSubmission> get visibleVerifications =>
      verifications.where((v) => v.decision == verificationTab).toList();

  VerificationSubmission? get selectedVerification {
    for (final v in verifications) {
      if (v.id == selectedVerificationId) return v;
    }
    return null;
  }

  void setVerificationTab(VerificationDecision tab) {
    verificationTab = tab;
    selectedVerificationIds.clear();
    _verificationAnchorId = null;
    final list = visibleVerifications;
    selectedVerificationId = list.isEmpty ? null : list.first.id;
    notifyListeners();
  }

  void selectVerification(String? id) {
    selectedVerificationId = id;
    notifyListeners();
  }

  String? _verificationAnchorId;

  void toggleVerificationSelection(String id, {bool extend = false}) {
    final rows = [for (final v in visibleVerifications) v.id];
    if (extend && _verificationAnchorId != null) {
      selectedVerificationIds.addAll(_range(rows, _verificationAnchorId!, id));
      notifyListeners();
      return;
    }
    if (!selectedVerificationIds.remove(id)) selectedVerificationIds.add(id);
    _verificationAnchorId = id;
    notifyListeners();
  }

  void clearVerificationSelection() {
    selectedVerificationIds.clear();
    _verificationAnchorId = null;
    notifyListeners();
  }

  final Set<String> verificationDecisionIds = {};

  bool verificationDecisionPending(String id) =>
      verificationDecisionIds.contains(id);

  Future<bool> decideVerification(
    String id,
    VerificationDecision outcome, {
    String reason = '',
    bool announce = true,
  }) async {
    if (backend != null && isInternalAdmin) {
      return _decideRemote(id, outcome, reason);
    }
    final submission = verifications.cast<VerificationSubmission?>().firstWhere(
      (v) => v?.id == id,
      orElse: () => null,
    );
    if (submission == null) return false;

    final before = submission.decision;
    submission
      ..decision = outcome
      ..reason = reason.isEmpty ? null : reason
      ..decidedAt = 'Just now';

    final released = _applyVerificationToAccount(submission, outcome);

    log(
      action: switch (outcome) {
        VerificationDecision.approved => 'verified',
        VerificationDecision.rejected => 'rejected the campus claim of',
        VerificationDecision.changesRequested =>
          'asked for a clearer document from',
        VerificationDecision.pending => 'reopened the verification for',
      },
      target: submission.name,
      kind: AuditKind.account,
      diff: [
        '${verificationLabel(before)}  →  ${verificationLabel(outcome)}',
        if (outcome == VerificationDecision.approved)
          'ID ${submission.idNumber} '
              '${submission.registryMatch ? 'matched' : 'not found in'} the '
              'registry',
        if (released > 0)
          '$released held request${released == 1 ? '' : 's'} released',
      ],
      reason: reason,
    );
    notifyListeners();

    if (released > 0) {
      showToast(
        ToastMessage(
          '${submission.name} verified · $released held '
          'request${released == 1 ? '' : 's'} released into the queue.',
        ),
      );
    }
    if (!announce) return true;
    toasts.show(
      ToastMessage.success(
        '${verificationLabel(outcome)} — ${submission.name}',
        action: ToastAction(
          label: 'Undo',
          onPressed: () {
            submission
              ..decision = before
              ..reason = null
              ..decidedAt = null;
            _applyVerificationToAccount(submission, before);
            log(
              action: 'undid the verification decision for',
              target: submission.name,
              kind: AuditKind.account,
              diff: [
                '${verificationLabel(outcome)}  →  '
                    '${verificationLabel(before)}',
              ],
            );
            notifyListeners();
          },
        ),
      ),
    );
    return true;
  }

  Future<bool> _decideRemote(
    String id,
    VerificationDecision outcome,
    String reason,
  ) async {
    final decision = switch (outcome) {
      VerificationDecision.approved => 'approved',
      VerificationDecision.changesRequested => 'changes_requested',
      VerificationDecision.rejected => 'rejected',
      VerificationDecision.pending => 'pending',
    };
    if (decision == 'pending' || !verificationDecisionIds.add(id)) return false;
    notifyListeners();
    try {
      await backend!.decideVerification(
        submissionId: id,
        decision: decision,
        reason: reason,
      );
      await refreshVerifications();
      verificationTab = outcome;
      selectedVerificationId = id;
      selectedVerificationIds.remove(id);
      showToast(
        ToastMessage(
          outcome == VerificationDecision.approved
              ? 'Campus member verified.'
              : outcome == VerificationDecision.rejected
              ? 'Campus claim rejected.'
              : 'A clearer document was requested.',
        ),
      );
      return true;
    } catch (error) {
      showToast(
        ToastMessage(
          'Verification decision failed: $error',
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    } finally {
      verificationDecisionIds.remove(id);
      notifyListeners();
    }
  }

  int _applyVerificationToAccount(
    VerificationSubmission submission,
    VerificationDecision outcome,
  ) {
    final account = accounts.cast<Account?>().firstWhere(
      (a) => a?.email == submission.email,
      orElse: () => null,
    );
    if (account == null) return 0;

    account.verification = switch (outcome) {
      VerificationDecision.approved => VerificationState.verified,
      VerificationDecision.rejected => VerificationState.rejected,
      _ => VerificationState.pending,
    };
    if (outcome == VerificationDecision.approved) {
      account.role = AccountRole.user;
    }
    return 0;
  }

  static String verificationLabel(VerificationDecision d) => switch (d) {
    VerificationDecision.pending => 'Awaiting review',
    VerificationDecision.approved => 'Verified campus member',
    VerificationDecision.changesRequested => 'Better document requested',
    VerificationDecision.rejected => 'Rejected',
  };

  void bulkVerify(Iterable<String> ids) {
    final list = ids.toList();
    if (list.isEmpty) return;
    for (final id in list) {
      unawaited(
        decideVerification(id, VerificationDecision.approved, announce: false),
      );
    }
    selectedVerificationIds.clear();
    notifyListeners();
    showToast(
      ToastMessage(
        '${list.length} member${list.length == 1 ? '' : 's'} verified.',
      ),
    );
  }

  int get _activeInternalAdmins => accounts
      .where(
        (a) =>
            a.role == AccountRole.internalAdmin &&
            a.status == AccountStatus.active,
      )
      .length;

  bool isLastInternalAdmin(Account account) =>
      account.role == AccountRole.internalAdmin &&
      account.status == AccountStatus.active &&
      _activeInternalAdmins <= 1;

  String? roleChangeBlockedReason(Account account) {
    if (account.isSelf) {
      return 'Nobody can change their own role — ask another internal admin.';
    }
    if (isLastInternalAdmin(account)) {
      return 'This is the last active internal admin. Demoting it would leave '
          'nobody able to approve verifications — invite a replacement first.';
    }
    return null;
  }

  Future<String?> changeRole(Account account, AccountRole role) async {
    if (role == account.role) return 'Choose a different role.';
    final blocked = roleChangeBlockedReason(account);
    if (blocked != null) return blocked;
    final before = account.role;
    if (backend != null) {
      try {
        final updated = await backend!.changeAccountRole(
          accountId: account.id,
          role: _roleRaw(role),
        );
        _upsertBackendAccount(updated);
      } catch (error) {
        return _accountActionError(error, 'Role change wasn’t saved.');
      }
    } else {
      account.role = role;
      notifyListeners();
    }
    log(
      action: 'changed the role of',
      target: account.name,
      kind: AuditKind.account,
      diff: ['${before.label}  →  ${role.label}'],
      revertable: true,
    );
    showToast(ToastMessage('${account.name} is now ${role.label}.'));
    return null;
  }

  Future<String?> suspendAccount(
    Account account,
    String reason,
    DateTime? until,
  ) async {
    if (account.isSelf) return 'You cannot suspend your own account.';
    if (reason.trim().isEmpty) return 'Enter a reason for the suspension.';
    if (until != null && !until.isAfter(DateTime.now())) {
      return 'Choose a future suspension lift date.';
    }
    if (backend != null) {
      try {
        final updated = await backend!.suspendUserAccount(
          accountId: account.id,
          reason: reason,
          suspendedUntil: until,
        );
        _upsertBackendAccount(updated);
      } catch (error) {
        return _accountActionError(error, 'Suspension wasn’t saved.');
      }
    } else {
      account
        ..status = AccountStatus.suspended
        ..suspendReason = reason
        ..suspendUntil = until == null ? null : _accountDate(until);
      notifyListeners();
    }
    final untilLabel = until == null ? '' : _accountDate(until);
    log(
      action: 'suspended',
      target: account.name,
      kind: AuditKind.account,
      diff: [
        'Active  →  Suspended${until == null ? ' indefinitely' : ' until $untilLabel'}',
        'New requests blocked · approved bookings stand',
      ],
      reason: reason,
      revertable: true,
    );
    showToast(ToastMessage('${account.name} is suspended.'));
    return null;
  }

  Future<String?> liftSuspension(Account account) async {
    if (backend != null) {
      try {
        _upsertBackendAccount(await backend!.liftUserSuspension(account.id));
      } catch (error) {
        return _accountActionError(error, 'Suspension couldn’t be lifted.');
      }
    } else {
      account
        ..status = AccountStatus.active
        ..suspendReason = null
        ..suspendUntil = null;
      notifyListeners();
    }
    log(
      action: 'lifted the suspension on',
      target: account.name,
      kind: AuditKind.account,
      diff: ['Suspended  →  Active'],
    );
    showToast(ToastMessage('${account.name} can request again.'));
    return null;
  }

  Future<String?> sendPasswordReset(Account account) async {
    if (backend != null) {
      try {
        _upsertBackendAccount(
          await backend!.sendAccountPasswordReset(account.id),
        );
      } catch (error) {
        return _accountActionError(error, 'Password reset wasn’t sent.');
      }
    }
    log(
      action: 'sent a password reset to',
      target: account.name,
      kind: AuditKind.account,
      diff: [
        'Reset link sent to ${account.email} · expires under the configured '
            'email policy',
      ],
      material: false,
    );
    notifyListeners();
    showToast(
      ToastMessage(
        'Reset link sent to ${account.email}. Passwords are never set for '
        'someone else.',
      ),
    );
    return null;
  }

  Future<String?> rerunVerification(Account account) async {
    if (backend != null) {
      try {
        _upsertBackendAccount(
          await backend!.requestAccountReverification(account.id),
        );
      } catch (error) {
        return _accountActionError(error, 'Re-verification wasn’t requested.');
      }
      log(
        action: 'requested re-verification for',
        target: account.name,
        kind: AuditKind.account,
        diff: ['A current campus document was requested'],
      );
      showToast(ToastMessage('${account.name} was asked to verify again.'));
      return null;
    }
    account.verification = VerificationState.pending;
    verifications = [
      VerificationSubmission(
        id: 'v-${DateTime.now().microsecondsSinceEpoch}',
        name: account.name,
        email: account.email,
        kind: account.idNumber.startsWith('F-')
            ? 'Faculty'
            : account.idNumber.startsWith('S-')
            ? 'University staff'
            : 'Student',
        idNumber: account.idNumber,
        unit: account.unit,
        document: 'Re-verification requested — awaiting a new document',
        submitted: 'Just now',
        registryMatch: true,
        nameMatch: true,
        alreadyClaimed: false,
        legible: true,
        decision: VerificationDecision.pending,
      ),
      ...verifications,
    ];
    log(
      action: 're-ran verification for',
      target: account.name,
      kind: AuditKind.account,
      diff: ['Verified  →  Awaiting review', 'Placed back in the queue'],
    );
    notifyListeners();
    showToast(
      ToastMessage('${account.name} is back in the verification queue.'),
    );
    return null;
  }

  Future<AdministratorCreationResult> createAdministrator(
    String email,
    AccountRole role,
    String note,
  ) async {
    final trimmed = email.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(trimmed)) {
      return const AdministratorCreationResult.failure(
        'Enter a valid email address.',
      );
    }
    if (accounts.any((a) => a.email.toLowerCase() == trimmed)) {
      return const AdministratorCreationResult.failure(
        'That address already has an account.',
      );
    }
    if (backend != null) {
      if (!isInternalAdmin) {
        return const AdministratorCreationResult.failure(
          'Only an internal admin can create administrators.',
        );
      }
      try {
        final created = await backend!.createAdministrator(
          email: trimmed,
          role: _roleRaw(role),
          note: note,
        );
        _upsertBackendAccount(created.account);
        log(
          action: 'created an administrator account for',
          target: '$trimmed as ${role.label}',
          kind: AuditKind.account,
          diff: ['Temporary credentials generated and shown once'],
          reason: note.trim(),
        );
        showToast(ToastMessage('Administrator account created for $trimmed.'));
        return AdministratorCreationResult.success(
          AdministratorCredentials(
            email: trimmed,
            temporaryPassword: created.temporaryPassword,
          ),
        );
      } catch (error) {
        return AdministratorCreationResult.failure(
          _accountActionError(error, 'Administrator wasn’t created.'),
        );
      }
    }

    final password = _temporaryPassword();
    accounts = [
      Account(
        id: 'u-${DateTime.now().microsecondsSinceEpoch}',
        name: trimmed,
        email: trimmed,
        role: role,
        unit: 'Administrator account created ${_today()}',
        idNumber: '—',
        verification: VerificationState.none,
        status: AccountStatus.active,
        reservations: 0,
        lastActive: 'Never',
        joined: _today(),
        noShows: 0,
      ),
      ...accounts,
    ];
    log(
      action: 'created an administrator account for',
      target: '$trimmed as ${role.label}',
      kind: AuditKind.account,
      diff: ['Temporary credentials generated and shown once'],
      reason: note.trim(),
    );
    notifyListeners();
    return AdministratorCreationResult.success(
      AdministratorCredentials(email: trimmed, temporaryPassword: password),
    );
  }

  Future<String?> inviteAdmin(
    String email,
    AccountRole role,
    String note,
  ) async {
    final trimmed = email.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(trimmed)) {
      return 'Enter a valid email address.';
    }
    if (accounts.any((a) => a.email.toLowerCase() == trimmed.toLowerCase())) {
      return 'That address already has an account.';
    }
    if (backend != null) {
      if (!isInternalAdmin) {
        return 'Only an internal admin can invite administrators.';
      }
      try {
        _upsertBackendAccount(
          await backend!.inviteAccountAdmin(
            email: trimmed,
            role: _roleRaw(role),
            note: note,
          ),
        );
      } catch (error) {
        return _accountActionError(error, 'Invitation wasn’t sent.');
      }
      log(
        action: 'invited',
        target: '$trimmed as ${role.label}',
        kind: AuditKind.account,
        diff: [
          'Invitation sent · single-use link',
          if (note.trim().isNotEmpty) 'Note: ${note.trim()}',
        ],
      );
      showToast(ToastMessage('Invitation sent to $trimmed.'));
      return null;
    }
    accounts = [
      ...accounts,
      Account(
        id: 'u-${DateTime.now().microsecondsSinceEpoch}',
        name: trimmed,
        email: trimmed,
        role: role,
        unit: 'Invitation sent ${_today()}',
        idNumber: '—',
        verification: VerificationState.none,
        status: AccountStatus.invited,
        reservations: 0,
        lastActive: 'Never',
        joined: '—',
        noShows: 0,
        invitationSentAt: DateTime.now(),
      ),
    ];
    log(
      action: 'invited',
      target: '$trimmed as ${role.label}',
      kind: AuditKind.account,
      diff: [
        'Invitation sent · single-use link',
        if (note.trim().isNotEmpty) 'Note: ${note.trim()}',
      ],
    );
    notifyListeners();
    showToast(ToastMessage('Invitation sent to $trimmed.'));
    return null;
  }

  Future<String?> inviteOrganizationRepresentative({
    required String email,
    required String slotId,
    String note = '',
  }) async {
    return 'Representative invitations are disabled in this prototype. Create a representative account with direct temporary credentials instead.';
  }

  static String _temporaryPassword() {
    const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const lower = 'abcdefghijkmnopqrstuvwxyz';
    const digits = '23456789';
    const symbols = '!@#\$%*-_';
    const all = '$upper$lower$digits$symbols';
    final random = Random.secure();
    String character(String alphabet) =>
        alphabet[random.nextInt(alphabet.length)];
    final characters = <String>[
      character(upper),
      character(lower),
      character(digits),
      character(symbols),
      for (var i = 0; i < 16; i++) character(all),
    ]..shuffle(random);
    return characters.join();
  }

  Future<String?> resendInvite(Account account) async {
    if (backend != null) {
      try {
        _upsertBackendAccount(await backend!.resendAdminInvite(account.id));
      } catch (error) {
        return _accountActionError(error, 'Invitation wasn’t resent.');
      }
    } else {
      account.invitationSentAt = DateTime.now();
      notifyListeners();
    }
    log(
      action: 'resent the invitation to',
      target: account.email,
      kind: AuditKind.account,
      diff: ['New single-use link · previous link invalidated'],
      material: false,
    );
    notifyListeners();
    showToast(ToastMessage('Invitation resent to ${account.email}.'));
    return null;
  }

  Future<String?> revokeInvite(Account account) async {
    if (backend != null) {
      try {
        final removedId = await backend!.revokeAdminInvite(account.id);
        accounts = accounts.where((a) => a.id != removedId).toList();
      } catch (error) {
        return _accountActionError(error, 'Invitation wasn’t revoked.');
      }
    } else {
      accounts = accounts.where((a) => a.id != account.id).toList();
    }
    log(
      action: 'revoked the invitation for',
      target: account.email,
      kind: AuditKind.account,
      diff: ['Invitation revoked · link no longer valid'],
    );
    notifyListeners();
    showToast(ToastMessage('Invitation for ${account.email} revoked.'));
    return null;
  }

  static String _roleRaw(AccountRole role) => switch (role) {
    AccountRole.user => 'user',
    AccountRole.internalAdmin => 'internal_admin',
    AccountRole.externalAdmin => 'external_admin',
  };

  void revertAudit(AuditEntry entry) {
    if (backend != null) {
      unawaited(_revertRemoteAudit(entry));
      return;
    }
    log(
      action: 'reverted a change to',
      target: entry.target,
      kind: entry.kind,
      diff: [
        'Reverting: ${entry.diff.isEmpty ? entry.action : entry.diff.first}',
        'Original entry ${entry.absolute} by ${entry.actor} is kept',
      ],
      reason: 'Reverted from the audit log.',
    );
    notifyListeners();
    showToast(
      const ToastMessage(
        'Reverted. The original entry is untouched — a new one records the '
        'reversal.',
      ),
    );
  }

  Future<void> _revertRemoteAudit(AuditEntry entry) async {
    try {
      await backend!.revertAuditEntry(entry.id, 'Reverted from the audit log.');
      await refreshAudit();
      await refreshFacilities();
      showToast(
        const ToastMessage('Reverted. A new audit entry records the reversal.'),
      );
    } catch (error) {
      showToast(
        ToastMessage(
          'This change could not be reverted: $error',
          tone: AdvisoryTone.block,
        ),
      );
    }
  }

  String exportAuditCsv(List<AuditEntry> rows) {
    if (backend == null) {
      log(
        action: 'exported the audit log',
        target: '${rows.length} entries',
        kind: AuditKind.account,
        diff: ['Exported by ${currentAdmin.name} · ${rows.length} rows'],
        material: false,
      );
      notifyListeners();
    }
    return [
      AuditEntry.csvHeader,
      for (final row in rows) row.toCsvRow(),
      '# exported by ${currentAdmin.name} (${currentAdmin.email}) '
          'on ${_today()}',
    ].join('\n');
  }

  String userAccountId = 'u1';

  Account get userAccount =>
      _sessionAccount ??
      accounts.firstWhere(
        (a) => a.id == userAccountId,
        orElse: () => accounts.first,
      );

  void signInAsUser(String accountId) {
    userAccountId = accountId;
    if (_useDemoData) {
      loyalty = _currentUserIsGuestPriced
          ? seedLoyalty(userId: userAccount.id)
          : _ineligibleLoyalty;
    }
    notifyListeners();
  }

  bool get userDetailsEditable =>
      !hasSession && userAccount.verification != VerificationState.verified;

  void updateUserDetail(String field, String value) {
    if (!userDetailsEditable) return;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    final account = userAccount;
    switch (field) {
      case 'name':
        account.name = trimmed;
      case 'idNumber':
        account.idNumber = trimmed;
      case 'unit':
        account.unit = trimmed;
    }
    notifyListeners();
  }

  List<ReservationRequest> get myRequests => [
    for (final r in requests)
      if (r.requesterId == userAccount.id ||
          (r.requesterId == null && r.requester == userAccount.name))
        r,
  ];

  bool canLeaveFeedback(ReservationRequest request) =>
      request.lifecycleStatus == ReservationLifecycleStatus.completed &&
      request.feedbackRating == null &&
      request.occurrences.any((o) => o.stage == BookingStage.completed);

  Future<bool> submitFeedback(
    ReservationRequest request, {
    required int rating,
    String comment = '',
    int? cleanliness,
    int? condition,
    int? equipment,
  }) async {
    if (_useDemoData) {
      if (feedbackSubmitting.contains(request.id)) return false;
      feedbackSubmitting.add(request.id);
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      request.feedbackRating = rating;
      request.feedbackComment = comment;
      request.feedbackAt = DateTime.now();
      feedbackEntries = [
        FeedbackEntry(
          feedback: ReservationFeedback(
            id: 'fb-demo-${DateTime.now().microsecondsSinceEpoch}',
            reservationId: request.id,
            facilityId: request.facilityId ?? '',
            facilityName: request.facility,
            userId: userAccount.id,
            rating: rating,
            cleanlinessRating: cleanliness,
            conditionRating: condition,
            equipmentRating: equipment,
            comment: comment,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
          reviewerName: userAccount.name,
        ),
        ...feedbackEntries,
      ];
      final earnsLoyalty =
          loyaltyAvailableForCurrentUser && request.pricingAudience == 'guest';
      if (earnsLoyalty) {
        loyalty = LoyaltySummary(
          eligible: true,
          balance: (loyalty?.balance ?? 0) + LoyaltyPoints.feedbackSubmitted,
          lifetimeEarned:
              (loyalty?.lifetimeEarned ?? 0) + LoyaltyPoints.feedbackSubmitted,
          lifetimeRedeemed: loyalty?.lifetimeRedeemed ?? 0,
          rules: loyalty?.rules ?? const {},
          transactions: [
            LoyaltyTransaction(
              id: 'lt-demo-${DateTime.now().microsecondsSinceEpoch}',
              userId: userAccount.id,
              points: LoyaltyPoints.feedbackSubmitted,
              type: LoyaltyTransactionType.feedbackSubmitted,
              sourceType: 'feedback',
              sourceId: request.id,
              description: 'Feedback for ${request.facility}',
              createdAt: DateTime.now(),
            ),
            ...(loyalty?.transactions ?? const []),
          ],
          redemptions: loyalty?.redemptions ?? const [],
          rewards: loyalty?.rewards ?? const [],
          offers: loyalty?.offers ?? const [],
          claims: loyalty?.claims ?? const [],
        );
      } else {
        loyalty = _ineligibleLoyalty;
      }
      feedbackSubmitting.remove(request.id);
      notifyListeners();
      toasts.show(
        ToastMessage.success(
          earnsLoyalty
              ? 'Thanks for rating ${request.facility} — you earned '
                    '${formatPoints(LoyaltyPoints.feedbackSubmitted)} points.'
              : 'Thanks for rating ${request.facility}.',
        ),
      );
      return true;
    }
    final service = _coreBackend;
    if (service == null || feedbackSubmitting.contains(request.id)) {
      return false;
    }
    feedbackSubmitting.add(request.id);
    notifyListeners();
    try {
      final saved = await service.submitFeedback(
        reservationId: request.id,
        rating: rating,
        comment: comment,
        cleanliness: cleanliness,
        condition: condition,
        equipment: equipment,
      );
      request.feedbackRating = saved.rating;
      request.feedbackComment = saved.comment;
      request.feedbackAt = saved.createdAt;
      notifyListeners();
      if (_currentUserIsGuestPriced) unawaited(refreshLoyalty());
      unawaited(refreshReservations());
      unawaited(refreshFacilities());
      toasts.show(
        ToastMessage.success('Thanks for rating ${request.facility}.'),
      );
      return true;
    } catch (error) {
      showToast(
        ToastMessage(
          friendlyBackendMessage('$error'),
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    } finally {
      feedbackSubmitting.remove(request.id);
      notifyListeners();
    }
  }

  Future<void> refreshFeedback({FeedbackQuery? query}) async {
    final service = _coreBackend;
    if (_useDemoData || service == null || !isAdmin) return;
    final requested = query ?? feedbackQuery;
    final requestId = ++_feedbackRequestId;
    feedbackQuery = requested;
    feedbackLoading = true;
    feedbackAnalyticsLoading = true;
    feedbackError = null;
    feedbackAnalyticsError = null;
    notifyListeners();

    Object? analyticsError;
    final analyticsFuture = service
        .feedbackSentimentAnalytics(requested)
        .catchError((Object error) {
          analyticsError = error;
          return const BackendFeedbackSentimentAnalytics();
        });

    try {
      try {
        final results = await Future.wait<Object>([
          service.feedbackEntries(requested),
          service.feedbackSummary(requested),
        ]);
        final page = results[0] as BackendFeedbackPage;
        final summary = results[1] as BackendFeedbackSummary;
        if (requestId == _feedbackRequestId) {
          feedbackEntries = [
            for (final row in page.entries)
              FeedbackEntry(
                feedback: row.toModel(),
                reviewerName: row.requesterName,
                reservationStartsAt: row.reservationStartsAt,
                pricingAudience: row.pricingAudience,
              ),
          ];
          feedbackEntriesTotal = page.total;
          feedbackSummaryData = summary.toModel();
        }
      } catch (error) {
        if (requestId == _feedbackRequestId) {
          feedbackError = friendlyBackendMessage('$error');
        }
      }

      final analytics = await analyticsFuture;
      if (requestId == _feedbackRequestId) {
        if (analyticsError == null) {
          feedbackSentimentAnalyticsData = analytics.toModel();
        } else {
          feedbackAnalyticsError = friendlyBackendMessage('$analyticsError');
        }
      }
    } finally {
      if (requestId == _feedbackRequestId) {
        feedbackLoading = false;
        feedbackAnalyticsLoading = false;
        notifyListeners();
      }
    }
  }

  void setFeedbackQuery(FeedbackQuery query) {
    unawaited(refreshFeedback(query: query));
  }

  Future<bool> retryFeedbackSentiment(String feedbackId) async {
    final service = _coreBackend;
    if (_useDemoData || service == null || !isAdmin) return false;
    if (feedbackSentimentRetrying.contains(feedbackId)) return false;
    feedbackSentimentRetrying.add(feedbackId);
    notifyListeners();
    try {
      await service.retryFeedbackSentiment(feedbackId);
      await refreshFeedback();
      toasts.show(const ToastMessage.success('Sentiment analysis was queued.'));
      return true;
    } catch (error) {
      showToast(
        ToastMessage(
          friendlyBackendMessage('$error'),
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    } finally {
      feedbackSentimentRetrying.remove(feedbackId);
      notifyListeners();
    }
  }

  Future<void> refreshLoyalty() async {
    if (!_currentUserIsGuestPriced) {
      _loyaltySubscription?.cancel();
      _loyaltySubscription = null;
      loyalty = _ineligibleLoyalty;
      loyaltyLoading = false;
      loyaltyError = null;
      notifyListeners();
      return;
    }
    if (_useDemoData) {
      loyalty = seedLoyalty(userId: userAccount.id);
      loyaltyError = null;
      notifyListeners();
      return;
    }
    final service = _coreBackend;
    if (service == null || !hasSession) return;
    loyaltyLoading = true;
    notifyListeners();
    try {
      final summary = await service.loyaltySummary();
      final model = summary.toModel();
      loyalty = model;
      loyaltyError = null;
      if (!model.eligible) {
        _loyaltySubscription?.cancel();
        _loyaltySubscription = null;
      }
    } catch (error) {
      loyaltyError = friendlyBackendMessage('$error');
    } finally {
      loyaltyLoading = false;
      notifyListeners();
    }
  }

  Future<bool> redeemReward(LoyaltyReward reward) async {
    if (!loyaltyAvailableForCurrentUser) {
      showToast(
        const ToastMessage(
          'Loyalty rewards are available to guest renters only.',
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    }
    if (redemptionsPending.contains(reward.id)) return false;
    redemptionsPending.add(reward.id);
    notifyListeners();
    if (_useDemoData) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final balance = loyalty?.balance ?? 0;
      if (balance < reward.pointsCost) {
        redemptionsPending.remove(reward.id);
        notifyListeners();
        showToast(
          const ToastMessage(
            'You do not have enough points for this reward yet.',
            tone: AdvisoryTone.block,
          ),
        );
        return false;
      }
      loyalty = LoyaltySummary(
        balance: balance - reward.pointsCost,
        lifetimeEarned: loyalty?.lifetimeEarned ?? 0,
        lifetimeRedeemed: (loyalty?.lifetimeRedeemed ?? 0) + reward.pointsCost,
        rules: loyalty?.rules ?? const {},
        transactions: [
          LoyaltyTransaction(
            id: 'lt-demo-${DateTime.now().microsecondsSinceEpoch}',
            userId: userAccount.id,
            points: -reward.pointsCost.toDouble(),
            type: LoyaltyTransactionType.rewardRedeemed,
            sourceType: 'redemption',
            sourceId: reward.id,
            description: reward.name,
            createdAt: DateTime.now(),
          ),
          ...(loyalty?.transactions ?? const []),
        ],
        redemptions: [
          LoyaltyRedemption(
            id: 'lr-demo-${DateTime.now().microsecondsSinceEpoch}',
            userId: userAccount.id,
            rewardId: reward.id,
            rewardName: reward.name,
            pointsSpent: reward.pointsCost,
            status: RedemptionStatus.issued,
            redemptionCode: 'DEMO${(1000 + Random().nextInt(9000))}',
            createdAt: DateTime.now(),
          ),
          ...(loyalty?.redemptions ?? const []),
        ],
        rewards: loyalty?.rewards ?? const [],
        offers: loyalty?.offers ?? const [],
        claims: loyalty?.claims ?? const [],
      );
      redemptionsPending.remove(reward.id);
      notifyListeners();
      toasts.show(ToastMessage.success('Redeemed ${reward.name}.'));
      return true;
    }
    final service = _coreBackend;
    if (service == null) {
      redemptionsPending.remove(reward.id);
      notifyListeners();
      return false;
    }
    try {
      final redemption = await service.redeemLoyaltyReward(reward.id);
      await refreshLoyalty();
      toasts.show(
        ToastMessage.success(
          'Redeemed ${reward.name} — code ${redemption.redemptionCode}.',
        ),
      );
      return true;
    } catch (error) {
      showToast(
        ToastMessage(
          friendlyBackendMessage('$error'),
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    } finally {
      redemptionsPending.remove(reward.id);
      notifyListeners();
    }
  }

  Future<void> refreshLoyaltyBalances({String search = ''}) async {
    final service = _coreBackend;
    if (_useDemoData || service == null || !isExternalAdmin) {
      if (!isExternalAdmin) _clearAdminLoyaltyState();
      return;
    }
    loyaltyBalancesLoading = true;
    loyaltyBalancesError = null;
    notifyListeners();
    try {
      final rows = await service.loyaltyBalances(search: search);
      loyaltyBalances = [for (final row in rows) row.toModel()];
    } catch (error) {
      loyaltyBalancesError = friendlyBackendMessage('$error');
    } finally {
      loyaltyBalancesLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshLoyaltyLedger(String userId, {int limit = 100}) async {
    final service = _coreBackend;
    if (_useDemoData || service == null || !isExternalAdmin) return;
    loyaltyLedgerLoading.add(userId);
    loyaltyLedgerErrors.remove(userId);
    notifyListeners();
    try {
      final rows = await service.loyaltyLedger(userId, limit: limit);
      loyaltyLedgerByUser[userId] = [for (final row in rows) row.toModel()];
    } catch (error) {
      loyaltyLedgerErrors[userId] = friendlyBackendMessage('$error');
    } finally {
      loyaltyLedgerLoading.remove(userId);
      notifyListeners();
    }
  }

  Future<void> refreshLoyaltyAdminClaims({
    String search = '',
    LoyaltyDiscountClaimStatus? status,
  }) async {
    final service = _coreBackend;
    if (_useDemoData || service == null || !isExternalAdmin) {
      if (!isExternalAdmin) _clearAdminLoyaltyState();
      return;
    }
    loyaltyAdminClaimsLoading = true;
    loyaltyAdminClaimsError = null;
    notifyListeners();
    try {
      final rows = await service.loyaltyAdminClaims(
        search: search,
        status: status?.raw,
      );
      loyaltyAdminClaims = [for (final row in rows) row.toModel()];
    } catch (error) {
      loyaltyAdminClaimsError = friendlyBackendMessage('$error');
    } finally {
      loyaltyAdminClaimsLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshExternalLoyaltyAdmin() async {
    if (!isExternalAdmin) {
      _clearAdminLoyaltyState();
      notifyListeners();
      return;
    }
    await Future.wait([
      refreshLoyaltyBalances(),
      refreshLoyaltyDiscountOffers(),
      refreshLoyaltyAdminClaims(),
    ]);
  }

  Future<bool> claimLoyaltyDiscount(LoyaltyDiscountOffer offer) async {
    if (!loyaltyAvailableForCurrentUser) {
      showToast(
        const ToastMessage(
          'Loyalty discounts are available to guest renters only.',
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    }
    if (discountClaimsPending.contains(offer.id)) return false;
    discountClaimsPending.add(offer.id);
    notifyListeners();
    if (_useDemoData) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final balance = loyalty?.balance ?? 0;
      if (balance < offer.requiredPoints) {
        discountClaimsPending.remove(offer.id);
        notifyListeners();
        showToast(
          const ToastMessage(
            'You do not have enough points for this discount yet.',
            tone: AdvisoryTone.block,
          ),
        );
        return false;
      }
      final claim = LoyaltyDiscountClaim(
        id: 'claim-demo-${DateTime.now().microsecondsSinceEpoch}',
        userId: userAccount.id,
        offerId: offer.id,
        offerName: offer.name,
        offerDescription: offer.description,
        discountKind: offer.discountKind,
        fixedAmountCentavos: offer.fixedAmountCentavos,
        percentage: offer.percentage,
        facilityId: offer.facilityId,
        facilityName: offer.facilityName,
        requiredPoints: offer.requiredPoints,
        expiryDate: offer.validUntil,
        pointsSpent: offer.requiredPoints,
        status: LoyaltyDiscountClaimStatus.claimed,
        claimedAt: DateTime.now(),
      );
      loyalty = LoyaltySummary(
        eligible: true,
        balance: balance - offer.requiredPoints,
        lifetimeEarned: loyalty?.lifetimeEarned ?? 0,
        lifetimeRedeemed:
            (loyalty?.lifetimeRedeemed ?? 0) + offer.requiredPoints,
        rules: loyalty?.rules ?? const {},
        transactions: [
          LoyaltyTransaction(
            id: 'lt-demo-${DateTime.now().microsecondsSinceEpoch}',
            userId: userAccount.id,
            points: -offer.requiredPoints,
            type: LoyaltyTransactionType.discountClaimed,
            sourceType: 'discount_claim',
            sourceId: claim.id,
            description: 'Claimed discount - ${offer.name}',
            createdAt: DateTime.now(),
          ),
          ...(loyalty?.transactions ?? const []),
        ],
        redemptions: loyalty?.redemptions ?? const [],
        rewards: loyalty?.rewards ?? const [],
        offers: loyalty?.offers ?? const [],
        claims: [claim, ...(loyalty?.claims ?? const [])],
      );
      discountClaimsPending.remove(offer.id);
      notifyListeners();
      toasts.show(ToastMessage.success('Claimed ${offer.name}.'));
      return true;
    }
    final service = _coreBackend;
    if (service == null) {
      discountClaimsPending.remove(offer.id);
      notifyListeners();
      return false;
    }
    try {
      await service.claimLoyaltyDiscount(offer.id);
      await refreshLoyalty();
      toasts.show(ToastMessage.success('Claimed ${offer.name}.'));
      return true;
    } catch (error) {
      showToast(
        ToastMessage(
          friendlyBackendMessage('$error'),
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    } finally {
      discountClaimsPending.remove(offer.id);
      notifyListeners();
    }
  }

  Future<void> refreshLoyaltyDiscountOffers() async {
    final service = _coreBackend;
    if (_useDemoData || service == null || !isExternalAdmin) return;
    loyaltyDiscountOffersLoading = true;
    loyaltyDiscountOffersError = null;
    notifyListeners();
    try {
      final rows = await service.loyaltyDiscountOffers();
      loyaltyDiscountOffers = [for (final row in rows) row.toModel()];
    } catch (error) {
      loyaltyDiscountOffersError = friendlyBackendMessage('$error');
    } finally {
      loyaltyDiscountOffersLoading = false;
      notifyListeners();
    }
  }

  Future<bool> adjustLoyaltyPoints({
    required String userId,
    required double points,
    required String reason,
  }) async {
    final service = _coreBackend;
    if (service == null || !isExternalAdmin) return false;
    try {
      await service.adjustLoyaltyPoints(
        userId: userId,
        points: points,
        reason: reason,
      );
      await refreshLoyaltyBalances();
      await refreshLoyaltyLedger(userId);
      toasts.show(
        ToastMessage.success(
          '${points > 0 ? '+' : ''}${formatPoints(points)} points — $reason',
        ),
      );
      return true;
    } catch (error) {
      showToast(
        ToastMessage(
          friendlyBackendMessage('$error'),
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    }
  }

  Future<bool> saveLoyaltyDiscountOffer({
    String? id,
    required String name,
    String description = '',
    required double requiredPoints,
    required DiscountKind discountKind,
    int? fixedAmountCentavos,
    double? percentage,
    String? facilityId,
    required DateTime validFrom,
    required DateTime validUntil,
    bool active = true,
  }) async {
    final service = _coreBackend;
    loyaltyDiscountOfferSaveError = null;
    if (service == null || !isExternalAdmin) {
      loyaltyDiscountOfferSaveError =
          'External administrator access is required.';
      notifyListeners();
      return false;
    }
    try {
      await service.saveLoyaltyDiscountOffer(
        id: id,
        name: name,
        description: description,
        requiredPoints: requiredPoints,
        discountKind: discountKind,
        fixedAmountCentavos: fixedAmountCentavos,
        percentage: percentage,
        facilityId: facilityId,
        validFrom: validFrom,
        validUntil: validUntil,
        active: active,
      );
      await refreshLoyaltyDiscountOffers();
      showToast(
        ToastMessage.success(
          id == null ? 'Discount created.' : 'Discount saved.',
        ),
      );
      return true;
    } catch (error) {
      final message = friendlyBackendMessage('$error');
      loyaltyDiscountOfferSaveError = message;
      showToast(ToastMessage(message, tone: AdvisoryTone.block));
      notifyListeners();
      return false;
    }
  }

  Future<bool> setLoyaltyDiscountOfferActive(
    String offerId,
    bool active,
  ) async {
    final service = _coreBackend;
    if (service == null || !isExternalAdmin) return false;
    try {
      await service.setLoyaltyDiscountOfferActive(offerId, active);
      await refreshLoyaltyDiscountOffers();
      return true;
    } catch (error) {
      showToast(
        ToastMessage(
          friendlyBackendMessage('$error'),
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    }
  }

  Future<void> refreshFacilityActivity(Facility facility) async {
    final service = _coreBackend;
    if (service == null || !facility.canManage) return;
    try {
      final rows = await service.facilityActivity(facility.id);
      audit = [
        ...rows,
        for (final entry in audit)
          if (entry.recordId != facility.id) entry,
      ];
      notifyListeners();
    } catch (_) {
      debugPrint('Failed to refresh activity for ${facility.name}.');
    }
  }

  static const hourlyRate = 500;

  int quoteFor(Facility facility, double hours) {
    final size = facility.capacity >= 400
        ? 3
        : (facility.capacity >= 80 ? 2 : 1);
    return (hourlyRate * size * hours).round();
  }

  Future<BackendReservationQuote?> quoteReservation({
    required Facility facility,
    required List<DateTime> startsAt,
    required List<DateTime> endsAt,
    int? headcount,
    List<String> amenityIds = const [],
    String? discountClaimId,
  }) async {
    final service = _coreBackend;
    if (service == null || _useDemoData || !hasSession) {
      final duration = startsAt.isEmpty || endsAt.isEmpty
          ? 0.0
          : endsAt.first.difference(startsAt.first).inMinutes / 60;
      final exempt = userAccount.isPaymentExempt;
      final total = exempt ? 0 : quoteFor(facility, duration) * 100;
      LoyaltyDiscountClaim? discount;
      for (final claim in loyalty?.claims ?? const <LoyaltyDiscountClaim>[]) {
        if (claim.id == discountClaimId && claim.appliesTo(facility.id)) {
          discount = claim;
          break;
        }
      }
      final int discountAmount = discount == null
          ? 0
          : switch (discount.discountKind) {
              DiscountKind.fixedAmount => min(
                discount.fixedAmountCentavos ?? 0,
                total,
              ),
              DiscountKind.percentage =>
                (total * ((discount.percentage ?? 0) / 100)).round(),
            };
      final discountedTotal = max(0, total - discountAmount);
      final percent = facility.downPaymentPercent;
      return BackendReservationQuote(
        facilityId: facility.id,
        audience: userAccount.pricingAudience,
        adminLane: userAccount.verification == VerificationState.verified
            ? 'internal'
            : 'external',
        facilityAmountCentavos: total,
        amenityAmountCentavos: 0,
        discountAmountCentavos: discountAmount,
        totalAmountCentavos: discountedTotal,
        requiredDownPaymentCentavos: (discountedTotal * percent + 99) ~/ 100,
        pricingFingerprint: 'demo',
        lines: const [],
        terms: const [],
        downPaymentPercent: percent,
        paymentExemption: switch (userAccount.pricingAudience) {
          'student' when exempt => 'verified_student',
          'faculty' when exempt => 'verified_faculty',
          _ => 'none',
        },
        discount: discount == null
            ? null
            : LoyaltyQuoteDiscount(
                claimId: discount.id,
                offerName: discount.offerName,
                discountKind: discount.discountKind,
                fixedAmountCentavos: discount.fixedAmountCentavos,
                percentage: discount.percentage,
                discountAmountCentavos: discountAmount,
                expiryDate: discount.expiryDate,
                facilityId: discount.facilityId,
              ),
      );
    }
    try {
      return await service.reservationQuote(
        facilityId: facility.id,
        startsAt: startsAt,
        endsAt: endsAt,
        headcount: headcount ?? 1,
        amenityIds: amenityIds,
        discountClaimId: discountClaimId,
      );
    } catch (error) {
      lastReservationError = _reservationError(error);
      return null;
    }
  }

  Future<bool> submitReservationRequest({
    required Facility facility,
    required List<DateTime> startsAt,
    required List<DateTime> endsAt,
    required int heads,
    required String purpose,
    List<ReservationUpload> attachments = const [],
    List<String> requestedAmenities = const [],
    List<String> amenityIds = const [],
    BackendReservationQuote? quote,
    bool acceptedTerms = false,
    String? discountClaimId,
  }) async {
    final normalizedRequestedAmenities = normalizeRequestedAmenityLabels(
      facility,
      requestedAmenities,
    );
    final service = backend;
    if (_useDemoData || service == null || !hasSession) {
      submitBooking(
        facility: facility,
        date: formatCampusDate(campusWallTime(startsAt.first)),
        start: _clock(campusWallTime(startsAt.first)),
        end: _clock(campusWallTime(endsAt.first)),
        heads: heads,
        purpose: purpose,
        amenities: normalizedRequestedAmenities,
        occurrenceStartsAt: [
          for (final value in startsAt) campusWallTime(value),
        ],
        occurrenceEndsAt: [for (final value in endsAt) campusWallTime(value)],
      );
      lastReservationError = null;
      return true;
    }
    if (reservationActionsPending.contains('submit')) return false;
    reservationActionsPending.add('submit');
    notifyListeners();
    try {
      final core = service is SmartReserveCoreBackend ? service : null;
      final authoritativeQuote =
          quote ??
          await quoteReservation(
            facility: facility,
            startsAt: startsAt,
            endsAt: endsAt,
            headcount: heads,
            amenityIds: amenityIds,
            discountClaimId: discountClaimId,
          );
      if (core != null && authoritativeQuote == null) {
        throw StateError(
          lastReservationError ?? 'The price could not be calculated.',
        );
      }
      if (core != null &&
          authoritativeQuote!.terms.isNotEmpty &&
          !acceptedTerms) {
        throw const FormatException(
          'Accept the current reservation and payment terms before submitting.',
        );
      }
      final duration = endsAt.first.difference(startsAt.first).inMinutes / 60;
      await service.submitReservation(
        ReservationDraft(
          facilityId: facility.id,
          purpose: purpose,
          headcount: heads,
          startsAt: startsAt,
          endsAt: endsAt,
          attachments: attachments,
          paymentAmountCentavos:
              authoritativeQuote?.totalAmountCentavos ??
              quoteFor(facility, duration) * 100,
          requestedAmenities: normalizedRequestedAmenities,
          amenityIds: amenityIds,
          termsVersionIds: [
            for (final term
                in authoritativeQuote?.terms ?? const <BackendTermsVersion>[])
              term.id,
          ],
          pricingFingerprint: core == null
              ? null
              : authoritativeQuote!.pricingFingerprint,
          discountClaimId: discountClaimId,
        ),
      );
      await refreshReservations();
      lastReservationError = null;
      showToast(
        ToastMessage(
          'Request sent to the assigned ${authoritativeQuote?.adminLane ?? 'facility'} administrator.',
        ),
      );
      return true;
    } catch (error) {
      lastReservationError = _reservationError(error);
      showToast(ToastMessage(lastReservationError!, tone: AdvisoryTone.block));
      return false;
    } finally {
      reservationActionsPending.remove('submit');
      notifyListeners();
    }
  }

  Future<bool> submitReservationPayment({
    required ReservationRequest request,
    required PaymentPurpose purpose,
    required int amountCentavos,
    required String referenceNumber,
    required ReservationUpload proof,
  }) async {
    final service = _coreBackend;
    if (service == null || !hasSession || _useDemoData) {
      showToast(
        const ToastMessage(
          'Payment submission requires the connected Supabase backend.',
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    }
    final key = 'payment:${request.id}';
    if (reservationActionsPending.contains(key)) return false;
    reservationActionsPending.add(key);
    notifyListeners();
    try {
      await service.submitPayment(
        PaymentSubmissionDraft(
          requestId: request.id,
          purpose: purpose,
          amountCentavos: amountCentavos,
          referenceNumber: referenceNumber.trim(),
          proof: proof,
        ),
      );
      await refreshReservations();
      showToast(const ToastMessage('Payment submitted for review'));
      return true;
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return false;
    } finally {
      reservationActionsPending.remove(key);
      notifyListeners();
    }
  }

  Future<bool> correctReservationPayment({
    required PaymentTransaction payment,
    required int amountCentavos,
    required String referenceNumber,
    required ReservationUpload proof,
  }) async {
    final service = _coreBackend;
    if (service == null || !hasSession || _useDemoData) {
      showToast(
        const ToastMessage(
          'Payment correction requires the connected Supabase backend.',
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    }
    final key = 'payment:${payment.id}';
    if (reservationActionsPending.contains(key)) return false;
    reservationActionsPending.add(key);
    notifyListeners();
    try {
      await service.correctPaymentSubmission(
        payment: payment,
        amountCentavos: amountCentavos,
        referenceNumber: referenceNumber.trim(),
        proof: proof,
      );
      await refreshReservations();
      showToast(const ToastMessage('Payment submitted for review'));
      return true;
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return false;
    } finally {
      reservationActionsPending.remove(key);
      notifyListeners();
    }
  }

  Future<bool> decideReservationPayment({
    required PaymentTransaction payment,
    required String decision,
    String? reason,
  }) async {
    final service = _coreBackend;
    if (service == null || !hasSession || _useDemoData) {
      return false;
    }
    final key = 'payment:${payment.id}';
    if (reservationActionsPending.contains(key)) return false;
    reservationActionsPending.add(key);
    notifyListeners();
    try {
      await service.decidePayment(
        paymentId: payment.id,
        decision: decision,
        reason: reason,
      );
      await refreshReservations();
      showToast(
        ToastMessage(
          decision == 'verify'
              ? 'Payment verified.'
              : 'Payment rejected and returned for correction.',
        ),
      );
      return true;
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return false;
    } finally {
      reservationActionsPending.remove(key);
      notifyListeners();
    }
  }

  Future<bool> submitReservationUseAssessment({
    required ReservationRequest request,
    required ReservationOccurrence occurrence,
    required int cleanlinessRating,
    required int equipmentConditionRating,
    required bool leftUnclean,
    required bool equipmentDamaged,
    required String comment,
    List<ReservationUpload> evidence = const [],
  }) async {
    final service = _coreBackend;
    if (service == null || !hasSession || _useDemoData) {
      return false;
    }
    final key = 'assessment:${occurrence.id}';
    if (reservationActionsPending.contains(key)) return false;
    reservationActionsPending.add(key);
    notifyListeners();
    try {
      await service.submitReservationUseAssessment(
        requestId: request.id,
        occurrenceId: occurrence.id,
        cleanlinessRating: cleanlinessRating,
        equipmentConditionRating: equipmentConditionRating,
        leftUnclean: leftUnclean,
        equipmentDamaged: equipmentDamaged,
        comment: comment,
        evidence: evidence,
      );
      await refreshReservations();
      await refreshAnomalyCenter();
      showToast(const ToastMessage('Post-use assessment saved.'));
      return true;
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return false;
    } finally {
      reservationActionsPending.remove(key);
      notifyListeners();
    }
  }

  Future<String?> reservationPaymentProofUrl(PaymentTransaction payment) async {
    final service = _coreBackend;
    if (service == null || !hasSession) return null;
    try {
      return await service.paymentProofUrl(payment.proofPath);
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return null;
    }
  }

  Future<bool> issuePermit(String requestId) async {
    final service = _coreBackend;
    if (service == null) return false;
    try {
      await service.issuePermit(requestId);
      await refreshReservations();
      return true;
    } catch (error) {
      showToast(
        ToastMessage(
          friendlyBackendMessage('$error'),
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    }
  }

  Future<bool> requestReservationSignature(String requestId) async {
    if (!isInternalAdmin || backend == null) return false;
    try {
      await backend!.requestReservationSignature(requestId);
      await refreshReservations();
      showToast(const ToastMessage('E-signature request sent.'));
      return true;
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return false;
    }
  }

  Future<bool> submitReservationSignature({
    required String signatureRequestId,
    required String requestId,
    required ReservationUpload signature,
  }) async {
    if (backend == null) return false;
    try {
      await backend!.submitReservationSignature(
        signatureRequestId: signatureRequestId,
        requestId: requestId,
        signature: signature,
      );
      await refreshReservations();
      showToast(const ToastMessage('Your e-signature was submitted.'));
      return true;
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return false;
    }
  }

  Future<bool> uploadCeoSignature(ReservationUpload signature) async {
    if (!isInternalAdmin || backend == null) return false;
    try {
      await backend!.uploadCeoSignature(signature);
      showToast(const ToastMessage('CEO signature updated.'));
      return true;
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return false;
    }
  }

  Future<Uint8List?> permitUserSignature(String signatureId) async {
    try {
      return await backend?.permitUserSignature(signatureId);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> protectedCeoSignature(
    String requestId,
    String permitId,
  ) async {
    try {
      return await backend?.protectedCeoSignature(requestId, permitId);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> officialCeoSignature(
    String requestId,
    String permitId,
  ) async {
    if (!isInternalAdmin) return null;
    try {
      return await backend?.officialCeoSignature(requestId, permitId);
    } catch (_) {
      return null;
    }
  }

  Future<void> uploadPermitPdf({
    required String permitId,
    required String requestId,
    required String requesterId,
    required String permitNumber,
    required int version,
    required Uint8List bytes,
  }) async {
    final service = _coreBackend;
    if (service == null) return;
    try {
      await service.uploadPermitPdf(
        permitId: permitId,
        requestId: requestId,
        requesterId: requesterId,
        permitNumber: permitNumber,
        version: version,
        bytes: bytes,
      );
    } catch (_) {}
  }

  Future<String?> permitPdfUrl(ReservationPermit permit) async {
    final path = permit.storagePath;
    final service = _coreBackend;
    if (path == null || path.isEmpty || service == null) return null;
    try {
      return await service.permitDownloadUrl(path);
    } catch (_) {
      return null;
    }
  }

  Future<bool> saveFacilityConfiguration(
    FacilityConfigurationDraft draft,
  ) async {
    final service = _coreBackend;
    if (service == null) return false;
    try {
      await service.saveFacilityConfiguration(draft);
      await refreshFacilities();
      showToast(const ToastMessage('Facility settings saved.'));
      return true;
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return false;
    }
  }

  String? lastReservationError;

  final Map<String, List<BusyWindow>> _busyCache = {};
  final Map<String, DateTime> _busyCacheAt = {};
  final Map<String, AvailabilitySource> _busyCacheSource = {};
  static const _busyCacheTtl = Duration(seconds: 60);

  bool busyWindowsDegraded = false;

  List<String> _busyKeysFor(
    List<Facility> targets,
    DateTime fromWall,
    DateTime toWall,
  ) {
    final keys = <String>[];
    for (final facility in targets) {
      for (
        var day = DateTime(fromWall.year, fromWall.month, fromWall.day);
        day.isBefore(toWall);
        day = day.add(const Duration(days: 1))
      ) {
        keys.add('${facility.id}|${dayKey(day)}');
      }
    }
    return keys;
  }

  Future<Map<String, List<BusyWindow>>> busyWindowsFor(
    List<Facility> targets, {
    required DateTime fromWall,
    required DateTime toWall,
  }) async {
    return (await availabilitySnapshotFor(
      targets,
      fromWall: fromWall,
      toWall: toWall,
    )).windows;
  }

  Future<AvailabilitySnapshot> availabilitySnapshotFor(
    List<Facility> targets, {
    required DateTime fromWall,
    required DateTime toWall,
    bool forceRefresh = false,
  }) async {
    if (targets.isEmpty) {
      return AvailabilitySnapshot(
        windows: const {},
        source: _useDemoData
            ? AvailabilitySource.demo
            : AvailabilitySource.live,
        fetchedAt: DateTime.now(),
      );
    }
    final keys = _busyKeysFor(targets, fromWall, toWall);
    final now = DateTime.now();
    final allCached = keys.every((key) {
      final cachedAt = _busyCacheAt[key];
      return cachedAt != null && now.difference(cachedAt) < _busyCacheTtl;
    });
    if (!forceRefresh && allCached) {
      final sources = {for (final key in keys) _busyCacheSource[key]};
      final source = sources.contains(AvailabilitySource.localFallback)
          ? AvailabilitySource.localFallback
          : _useDemoData
          ? AvailabilitySource.demo
          : AvailabilitySource.live;
      return AvailabilitySnapshot(
        windows: {for (final key in keys) key: _busyCache[key] ?? const []},
        source: source,
        fetchedAt: now,
      );
    }

    var byKey = <String, List<BusyWindow>>{for (final key in keys) key: []};
    var source = _useDemoData
        ? AvailabilitySource.demo
        : AvailabilitySource.localFallback;
    final service = backend;
    if (!_useDemoData && service != null && hasSession) {
      try {
        final ids = {for (final facility in targets) facility.id}.toList();
        var cursor = DateTime(fromWall.year, fromWall.month, fromWall.day);
        while (cursor.isBefore(toWall)) {
          final chunkEnd = cursor.add(const Duration(days: 120));
          final cappedEnd = chunkEnd.isBefore(toWall) ? chunkEnd : toWall;
          final rows = await service.facilityBusyWindows(
            facilityIds: ids,
            from: campusInstant(cursor),
            to: campusInstant(cappedEnd),
          );
          for (final row in rows) {
            final startWall = campusWallTime(row.startsAt);
            final endWall = campusWallTime(row.endsAt);
            final key = '${row.facilityId}|${dayKey(startWall)}';
            byKey
                .putIfAbsent(key, () => [])
                .add(
                  BusyWindow(
                    startWall.hour + startWall.minute / 60,
                    endWall.hour + endWall.minute / 60,
                  ),
                );
          }
          cursor = cappedEnd;
        }
        _addOwnRequestsToBusyMap(targets, byKey);
        busyWindowsDegraded = false;
        source = AvailabilitySource.live;
      } catch (_) {
        busyWindowsDegraded = true;
        byKey = _localBusyWindows(targets, fromWall, toWall);
        source = AvailabilitySource.localFallback;
      }
    } else {
      byKey = _localBusyWindows(targets, fromWall, toWall);
      source = _useDemoData
          ? AvailabilitySource.demo
          : AvailabilitySource.localFallback;
      busyWindowsDegraded = !_useDemoData;
    }

    final stamped = now;
    for (final key in keys) {
      _busyCache[key] = byKey[key] ?? const [];
      _busyCacheAt[key] = stamped;
      _busyCacheSource[key] = source;
    }
    return AvailabilitySnapshot(
      windows: {for (final key in keys) key: byKey[key] ?? const []},
      source: source,
      fetchedAt: stamped,
    );
  }

  String? _facilityIdFor(ReservationRequest request) =>
      request.facilityId ?? facilityNamed(request.facility)?.id;

  void _addOwnRequestsToBusyMap(
    List<Facility> targets,
    Map<String, List<BusyWindow>> byKey,
  ) {
    final ids = {for (final facility in targets) facility.id};
    for (final request in requests) {
      if (request.requesterId != userAccount.id &&
          !(request.requesterId == null &&
              request.requester == userAccount.name)) {
        continue;
      }
      final facilityId = _facilityIdFor(request);
      if (facilityId == null || !ids.contains(facilityId)) continue;
      for (final occurrence in request.occurrences) {
        if (occurrence.bookingState != 'held' &&
            occurrence.bookingState != 'booked') {
          continue;
        }
        final startWall = campusWallTime(occurrence.startsAt);
        final endWall = campusWallTime(occurrence.endsAt);
        final key = '$facilityId|${dayKey(startWall)}';
        byKey
            .putIfAbsent(key, () => [])
            .add(
              BusyWindow(
                startWall.hour + startWall.minute / 60,
                endWall.hour + endWall.minute / 60,
              ),
            );
      }
    }
  }

  Map<String, List<BusyWindow>> _localBusyWindows(
    List<Facility> targets,
    DateTime fromWall,
    DateTime toWall,
  ) {
    final byKey = <String, List<BusyWindow>>{};
    final idsByName = {
      for (final facility in targets) facility.name: facility.id,
    };
    final rangeStart = DateTime(fromWall.year, fromWall.month, fromWall.day);

    final coveredOccurrenceIds = <String>{};

    for (final booking in bookings) {
      coveredOccurrenceIds.add(booking.id);
      final facilityId = idsByName[booking.facility];
      if (facilityId == null) continue;
      final date = parseCampusDate(booking.date);
      if (date == null) continue;
      if (date.isBefore(rangeStart) || !date.isBefore(toWall)) continue;
      final key = '$facilityId|${dayKey(date)}';
      byKey
          .putIfAbsent(key, () => [])
          .add(BusyWindow(parseClock(booking.start), parseClock(booking.end)));
    }

    for (final request in requests) {
      if (request.status != RequestStatus.approved) continue;
      final facilityId = idsByName[request.facility];
      if (facilityId == null) continue;
      for (final occurrence in request.occurrences) {
        if (!occurrence.isBooked) continue;
        if (coveredOccurrenceIds.contains(occurrence.id)) continue;
        final startWall = campusWallTime(occurrence.startsAt);
        final endWall = campusWallTime(occurrence.endsAt);
        if (startWall.isBefore(rangeStart) || !startWall.isBefore(toWall)) {
          continue;
        }
        final key = '$facilityId|${dayKey(startWall)}';
        byKey
            .putIfAbsent(key, () => [])
            .add(
              BusyWindow(
                startWall.hour + startWall.minute / 60,
                endWall.hour + endWall.minute / 60,
              ),
            );
      }
    }
    return byKey;
  }

  void invalidateBusyCache(String facilityId, DateTime day) {
    final key = '$facilityId|${dayKey(day)}';
    _busyCache.remove(key);
    _busyCacheAt.remove(key);
    _busyCacheSource.remove(key);
  }

  static const _cancellableBookingStates = {
    'requested',
    'held',
    'booked',
    'changes_requested',
    'bumped',
  };

  bool canCancelOccurrence(
    ReservationRequest request,
    ReservationOccurrence occurrence, {
    DateTime? now,
  }) {
    if (request.status == RequestStatus.cancelled ||
        request.status == RequestStatus.declined ||
        request.status == RequestStatus.expired ||
        request.lifecycleStatus == ReservationLifecycleStatus.cancelled ||
        request.lifecycleStatus == ReservationLifecycleStatus.declined ||
        request.lifecycleStatus == ReservationLifecycleStatus.expired ||
        request.lifecycleStatus == ReservationLifecycleStatus.completed) {
      return false;
    }
    return occurrence.startsAt.isAfter(now ?? campusNow()) &&
        occurrence.stage == BookingStage.booked &&
        _cancellableBookingStates.contains(occurrence.bookingState);
  }

  List<ReservationOccurrence> cancellableOccurrences(
    ReservationRequest request, {
    DateTime? now,
  }) => [
    for (final occurrence in request.occurrences)
      if (canCancelOccurrence(request, occurrence, now: now)) occurrence,
  ];

  bool canCancelReservation(ReservationRequest request, {DateTime? now}) =>
      cancellableOccurrences(request, now: now).isNotEmpty;

  bool _hasFutureActiveOccurrence(ReservationRequest request, {DateTime? now}) {
    final current = now ?? campusNow();
    return request.occurrences.any(
      (occurrence) =>
          occurrence.startsAt.isAfter(current) &&
          (occurrence.stage == BookingStage.booked ||
              occurrence.stage == BookingStage.checkedIn) &&
          _cancellableBookingStates.contains(occurrence.bookingState),
    );
  }

  Future<bool> cancelReservation(
    ReservationRequest request, {
    String reason = '',
    String? occurrenceId,
  }) async {
    final eligible = cancellableOccurrences(request);
    if (eligible.isEmpty ||
        (occurrenceId != null &&
            !eligible.any((occurrence) => occurrence.id == occurrenceId))) {
      showToast(
        const ToastMessage(
          'Only future reservations that have not started can be cancelled.',
          tone: AdvisoryTone.block,
        ),
      );
      return false;
    }
    if (_useDemoData || backend == null) {
      final cancelledIds = {
        for (final occurrence in eligible)
          if (occurrenceId == null || occurrence.id == occurrenceId)
            occurrence.id,
      };
      for (var i = 0; i < request.occurrences.length; i++) {
        final occurrence = request.occurrences[i];
        if (!cancelledIds.contains(occurrence.id)) continue;
        request.occurrences[i] = ReservationOccurrence(
          id: occurrence.id,
          startsAt: occurrence.startsAt,
          endsAt: occurrence.endsAt,
          bookingState: 'cancelled',
          stage: occurrence.stage,
          proposedStartsAt: occurrence.proposedStartsAt,
          proposedEndsAt: occurrence.proposedEndsAt,
          reason: reason.trim().isEmpty ? 'Cancelled by requester' : reason,
        );
      }
      if (!_hasFutureActiveOccurrence(request)) {
        request
          ..status = RequestStatus.cancelled
          ..lifecycleStatus = ReservationLifecycleStatus.cancelled
          ..reason = reason.trim().isEmpty
              ? 'Cancelled by requester'
              : reason.trim();
      }
      notifyListeners();
      showToast(const ToastMessage.success('Cancellation saved.'));
      return true;
    }
    final payload = <String, dynamic>{};
    if (occurrenceId != null) payload['occurrence_id'] = occurrenceId;
    return _runReservationActionWithResult(
      request,
      'cancel',
      reason: reason,
      payload: payload,
    );
  }

  void acceptReservationAlternative(
    ReservationRequest request,
    ReservationOccurrence occurrence,
  ) => unawaited(
    _runReservationAction(
      request,
      'accept_alternative',
      payload: {'occurrence_id': occurrence.id},
    ),
  );

  void resubmitReservation(
    ReservationRequest request, {
    required String purpose,
    required int headcount,
    required ReservationOccurrence occurrence,
    required DateTime startsAt,
    required DateTime endsAt,
  }) => unawaited(
    _runReservationAction(
      request,
      'resubmit',
      payload: {
        'purpose': purpose,
        'headcount': headcount,
        'occurrence_id': occurrence.id,
        'starts_at': campusInstant(startsAt).toIso8601String(),
        'ends_at': campusInstant(endsAt).toIso8601String(),
      },
    ),
  );

  Future<String?> reservationAttachmentUrl(ReservationFile file) async {
    try {
      return await backend?.reservationAttachmentUrl(file.storagePath);
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return null;
    }
  }

  ReservationRequest submitBooking({
    required Facility facility,
    required String date,
    required String start,
    required String end,
    required int heads,
    required String purpose,
    List<String> amenities = const [],
    List<DateTime> occurrenceStartsAt = const [],
    List<DateTime> occurrenceEndsAt = const [],
  }) {
    final account = userAccount;
    if (account.status == AccountStatus.suspended) {
      throw StateError(
        account.suspendReason ??
            'This account is suspended and cannot submit new requests.',
      );
    }
    final audience = account.pricingAudience;
    final configuredRate = facility.hourlyRateCentavosFor(audience);
    final amountCentavos = account.isPaymentExempt
        ? 0
        : facility.audienceRates.isNotEmpty
        ? (configuredRate * (parseClock(end) - parseClock(start)).abs()).round()
        : quoteFor(facility, (parseClock(end) - parseClock(start)).abs()) * 100;
    final fallbackDay = parseCampusDate(date) ?? campusNow();
    DateTime at(String clock) {
      final minutes = (parseClock(clock) * 60).round();
      return DateTime(
        fallbackDay.year,
        fallbackDay.month,
        fallbackDay.day,
        minutes ~/ 60,
        minutes % 60,
      );
    }

    final starts = occurrenceStartsAt.isEmpty
        ? [at(start)]
        : occurrenceStartsAt;
    final fallbackDuration = Duration(
      minutes: ((parseClock(end) - parseClock(start)) * 60).round(),
    );
    final ends = occurrenceEndsAt.length == starts.length
        ? occurrenceEndsAt
        : [for (final value in starts) value.add(fallbackDuration)];
    final request = ReservationRequest(
      id: 'r-${DateTime.now().microsecondsSinceEpoch}',
      facility: facility.name,
      building: facility.building,
      room: facility.room,
      capacity: facility.capacity,
      requester: account.name,
      role: '${account.role.label} · ${account.unit}',
      org: account.unit,
      purpose: purpose,
      date: date,
      start: start,
      end: end,
      heads: heads,
      submitted: 'Just now',
      urgent: false,
      attachments: 0,
      noShows: account.noShows,
      status: RequestStatus.pending,
      heldForVerification: false,
      paymentAmountCentavos: amountCentavos,
      paymentStatus: amountCentavos == 0
          ? PaymentTrackingStatus.notRequired
          : PaymentTrackingStatus.quoted,
      amenities: amenities,
      adminLane: account.verification == VerificationState.verified
          ? 'internal'
          : 'external',
      pricingAudience: audience,
      facilityAmountCentavos: amountCentavos,
      totalAmountCentavos: amountCentavos,
      downPaymentPercent: facility.downPaymentPercent,
      paymentExemption: switch (audience) {
        'student' when account.isPaymentExempt => 'verified_student',
        'faculty' when account.isPaymentExempt => 'verified_faculty',
        _ => 'none',
      },
      requiredDownPaymentCentavos:
          (amountCentavos * facility.downPaymentPercent + 99) ~/ 100,
      occurrences: [
        for (var i = 0; i < starts.length; i++)
          ReservationOccurrence(
            id: 'demo-occ-${DateTime.now().microsecondsSinceEpoch}-$i',
            startsAt: starts[i],
            endsAt: ends[i],
          ),
      ],
    );
    requests = [request, ...requests];
    account.reservations += 1;
    log(
      action: 'submitted a reservation request for',
      target: facility.name,
      kind: AuditKind.reservation,
      diff: [
        '$date · $start–$end · $heads people',
        'Admin lane: ${account.verification == VerificationState.verified ? 'internal' : 'external'}',
        if (amenities.isNotEmpty) 'Amenities: ${amenities.join(', ')}',
      ],
      material: false,
    );
    notifyListeners();
    showToast(
      const ToastMessage(
        'Request sent to the assigned facility administrator.',
      ),
    );
    return request;
  }

  static String _today() {
    final now = DateTime.now();
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
    return '${now.day} ${months[now.month - 1]} ${now.year}';
  }

  static String _formatProfileDate(DateTime? value) {
    if (value == null) return 'Unknown';
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
    final local = value.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }
}
