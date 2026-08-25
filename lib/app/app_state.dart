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
import '../model/audit_diff.dart';
import '../model/audit_entry.dart';
import '../model/calendar_event.dart';
import '../model/facility.dart';
import '../model/facility_draft.dart';
import '../model/feedback.dart';
import '../model/loyalty.dart';
import '../model/notice.dart';
import '../model/payment.dart';
import '../model/reservation.dart';
import '../model/verification.dart';
import '../features/assistant/assistant_availability.dart';
import '../features/reports/reports_data.dart';
import '../features/reservations/conflict_engine.dart';
import '../util/backend_errors.dart';
import '../util/campus_calendar.dart';
import '../util/geo.dart';
import '../theme/sr_theme.dart';
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

class AppState extends ChangeNotifier {
  AppState({bool useDemoData = true}) : _useDemoData = useDemoData {
    facilities = useDemoData ? seedFacilities() : [];
    requests = useDemoData ? seedRequests() : [];
    bookings = useDemoData ? [...seedBookings(), ...seriesDemoBookings()] : [];
    verifications = useDemoData ? seedVerifications() : [];
    accounts = useDemoData ? seedAccounts() : [];
    audit = useDemoData ? seedAudit() : [];
    calendarAnchor = useDemoData ? campusToday : campusNow();
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
    if (isExternalAdmin &&
        (next == AppView.verifications ||
            next == AppView.audit ||
            next == AppView.loyalty)) {
      showToast(
        const ToastMessage(
          'This administrator role cannot access that area.',
          tone: AdvisoryTone.block,
        ),
      );
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
    if (next == AppView.loyalty) unawaited(refreshLoyaltyBalances());
    closeOverlays();
    notifyListeners();
  }

  Future<void> refreshReports({ReportScope? scope}) async {
    final service = backend;
    if (_useDemoData || service == null || !isAdmin) return;
    final requested = scope ?? ReportScope.forRange(ReportRange.month);
    final requestId = ++_reportRequestId;
    reportScope = requested;
    if (reportSnapshot != null &&
        !reportSnapshot!.hasSameSelection(requested)) {
      reportSnapshot = null;
    }
    reportsLoading = true;
    reportsError = null;
    reportsStale = false;
    notifyListeners();
    try {
      final result = await service.adminReport(requested);
      if (requestId != _reportRequestId) return;
      reportSnapshot = result;
      reportsStale = false;
    } catch (error) {
      if (requestId != _reportRequestId) return;
      reportsError = _reportError(error);
      reportsStale = reportSnapshot?.hasSameSelection(requested) ?? false;
    } finally {
      if (requestId == _reportRequestId) {
        reportsLoading = false;
        notifyListeners();
      }
    }
  }

  static String _reportError(Object error) {
    final text = error.toString().toLowerCase();
    if (error is FormatException) {
      return 'The reporting service returned data that could not be verified.';
    }
    if (text.contains('pgrst202') ||
        text.contains('could not find the function') ||
        text.contains('schema cache')) {
      return 'Reporting is temporarily unavailable while the database service is updated.';
    }
    if (text.contains('42501') ||
        text.contains('administrator access required') ||
        text.contains('permission denied')) {
      return 'Your account does not have permission to view this report.';
    }
    if (text.contains('22023') || text.contains('invalid report range')) {
      return 'The selected reporting range is invalid. Choose another range.';
    }
    if (text.contains('socket') ||
        text.contains('network') ||
        text.contains('timeout') ||
        text.contains('failed host lookup') ||
        text.contains('connection')) {
      return 'Reports could not connect to SmartReserve. Check the connection and retry.';
    }
    return 'Reports could not be loaded. Retry in a moment.';
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
  late List<AuditEntry> audit;
  late List<Booking> bookings;
  ReportSnapshot? reportSnapshot;
  ReportScope? reportScope;
  int _reportRequestId = 0;
  bool reportsLoading = false;
  String? reportsError;
  bool reportsStale = false;
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
  bool feedbackLoading = false;
  String? feedbackError;
  int _feedbackRequestId = 0;

  // Loyalty
  LoyaltySummary? loyalty;
  bool loyaltyLoading = false;
  String? loyaltyError;
  final Set<String> redemptionsPending = {};
  List<LoyaltyBalanceRow> loyaltyBalances = [];
  bool loyaltyBalancesLoading = false;
  String? loyaltyBalancesError;
  bool pendingLoyaltyOpen = false;

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

  bool get hasSession => sessionProfile != null;
  bool get isInternalAdmin => sessionProfile?.isInternalAdmin ?? false;
  bool get isExternalAdmin => sessionProfile?.isExternalAdmin ?? false;
  bool get isAdmin => sessionProfile?.isAdmin ?? false;

  void configureBackend(SmartReserveBackend service) {
    backend = service;
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
    if (profile == null) {
      _reportRequestId++;
      reportSnapshot = null;
      reportScope = null;
      reportsLoading = false;
      reportsError = null;
      reportsStale = false;
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
      if (!_useDemoData) accounts = [];
      accountsLoading = false;
      accountsError = null;
      loyalty = null;
      loyaltyError = null;
      notifyListeners();
      return;
    }
    await refreshFacilities();
    _facilitySubscription = backend?.facilityStream().listen(
      _applyFacilityRows,
      onError: (Object error) {
        facilitiesError = 'Facilities could not refresh: $error';
        facilitiesLoading = false;
        notifyListeners();
      },
    );
    await refreshReservations();
    _reservationSubscription = backend?.reservationStream().listen(
      _applyReservationRows,
      onError: (Object error) {
        reservationsError = 'Reservations could not refresh: $error';
        reservationsLoading = false;
        notifyListeners();
      },
    );
    await refreshNotifications();
    _notificationSubscription = backend?.notificationStream().listen(
      _applyNotifications,
      onError: (Object error) {
        notificationsError = 'Notifications could not refresh: $error';
        notifyListeners();
      },
    );
    if (profile.isInternalAdmin) {
      await refreshAccounts();
      _accountSubscription = backend?.accountStream().listen(
        _applyBackendAccounts,
        onError: (Object error) {
          accountsError = 'Accounts could not refresh: ${_accountError(error)}';
          accountsLoading = false;
          notifyListeners();
        },
      );
      await refreshVerifications();
      _verificationSubscription = backend?.verificationStream().listen(
        (_) {
          unawaited(refreshVerifications());
        },
        onError: (Object error) =>
            debugPrint('Verifications live refresh failed: $error'),
      );
      view = AppView.facilities;
    } else if (profile.isExternalAdmin) {
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
        await refreshAccounts();
      }
      view = AppView.facilities;
    } else {
      if (!_useDemoData) accounts = [];
      myVerification = await backend?.currentVerification();
      verifications = myVerification == null
          ? []
          : [_toVerification(myVerification!)];
      _syncSessionAccount();
      _verificationSubscription = backend?.verificationStream().listen(
        (_) {
          unawaited(refreshMyVerification());
        },
        onError: (Object error) =>
            debugPrint('Verification live refresh failed: $error'),
      );
      await refreshLoyalty();
      _loyaltySubscription = _coreBackend?.loyaltyTransactionStream().listen(
        (_) {
          unawaited(refreshLoyalty());
        },
        onError: (Object error) =>
            debugPrint('Loyalty live refresh failed: $error'),
      );
      view = myVerification != null || !profile.onboardingComplete
          ? AppView.auth
          : AppView.userApp;
    }
    notifyListeners();
  }

  Future<void> refreshMyVerification() async {
    myVerification = await backend?.currentVerification();
    verifications = myVerification == null
        ? []
        : [_toVerification(myVerification!)];
    _syncSessionAccount();
    notifyListeners();
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

    final existing = _sessionAccount;
    if (existing != null && existing.id == profile.id) {
      existing
        ..name = profile.fullName
        ..email = profile.email
        ..role = AccountRole.fromRaw(profile.role)
        ..unit = profile.unit ?? ''
        ..idNumber = profile.campusId ?? ''
        ..verification = _sessionVerification
        ..status = AccountStatus.fromRaw(profile.accountStatus)
        ..suspendReason = profile.suspensionReason
        ..suspendUntil = profile.suspendedUntil == null
            ? null
            : _accountDate(profile.suspendedUntil);
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
      return 'SmartReserve could not complete this account action. Try again.';
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
    _verificationSubscription?.cancel();
    _facilitySubscription?.cancel();
    _accountSubscription?.cancel();
    _reservationSubscription?.cancel();
    _notificationSubscription?.cancel();
    _loyaltySubscription?.cancel();
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
      if (request != null) {
        requestTab = request.status;
        selectedRequestId = request.id;
      }
      notifyListeners();
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
        throw StateError('You are not assigned to manage this facility.');
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
    requestTab = request.status;
    selectedRequestId = request.id;
    selectedRequestIds.clear();
    _requestAnchorId = null;
    view = AppView.reservations;
    closeOverlays();
    notifyListeners();
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
    requestTab = tab;
    selectedRequestIds.clear();
    _requestAnchorId = null;
    final list = visibleRequests;
    selectedRequestId = list.isEmpty ? null : list.first.id;
    notifyListeners();
  }

  void selectRequest(String? id) {
    selectedRequestId = id;
    notifyListeners();
  }

  void stepRequestSelection(int delta) {
    final list = visibleRequests;
    if (list.isEmpty) return;
    final index = list.indexWhere((r) => r.id == selectedRequestId);
    final next = (index < 0 ? 0 : index + delta).clamp(0, list.length - 1);
    selectedRequestId = list[next].id;
    notifyListeners();
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
      final actionId = result.actionId;
      if (reversible && actionId != null) {
        toasts.show(
          ToastMessage.success(
            '${_actionLabel(action)} — ${request.requester}',
            action: ToastAction(
              label: 'Undo',
              onPressed: () => unawaited(_undoBackendReservation(actionId)),
            ),
          ),
        );
      } else if (announce) {
        toasts.show(ToastMessage.success('${_actionLabel(action)} saved.'));
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
      if (result.actionIds.isNotEmpty) {
        toasts.show(
          ToastMessage.success(
            '${ids.length} approvals',
            action: ToastAction(
              label: 'Undo',
              onPressed: () => unawaited(
                _undoBackendReservations(result.actionIds.reversed),
              ),
            ),
          ),
        );
      } else {
        toasts.show(ToastMessage.success('${ids.length} requests approved.'));
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
      loyalty = LoyaltySummary(
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
      );
      feedbackSubmitting.remove(request.id);
      notifyListeners();
      toasts.show(
        ToastMessage.success(
          'Thanks for rating ${request.facility} — you earned '
          '${LoyaltyPoints.feedbackSubmitted} points.',
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
      unawaited(refreshLoyalty());
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
    feedbackError = null;
    notifyListeners();
    try {
      final page = await service.feedbackEntries(requested);
      final summary = await service.feedbackSummary(requested);
      if (requestId != _feedbackRequestId) return;
      feedbackEntries = [
        for (final row in page.entries)
          FeedbackEntry(
            feedback: row.toModel(),
            reviewerName: row.requesterName,
          ),
      ];
      feedbackEntriesTotal = page.total;
      feedbackSummaryData = summary.toModel();
    } catch (error) {
      if (requestId != _feedbackRequestId) return;
      feedbackError = friendlyBackendMessage('$error');
    } finally {
      if (requestId == _feedbackRequestId) {
        feedbackLoading = false;
        notifyListeners();
      }
    }
  }

  void setFeedbackQuery(FeedbackQuery query) {
    unawaited(refreshFeedback(query: query));
  }

  Future<void> refreshLoyalty() async {
    if (_useDemoData) {
      loyalty ??= seedLoyalty();
      notifyListeners();
      return;
    }
    final service = _coreBackend;
    if (service == null || !hasSession) return;
    loyaltyLoading = true;
    notifyListeners();
    try {
      final summary = await service.loyaltySummary();
      loyalty = summary.toModel();
      loyaltyError = null;
    } catch (error) {
      loyaltyError = friendlyBackendMessage('$error');
    } finally {
      loyaltyLoading = false;
      notifyListeners();
    }
  }

  Future<bool> redeemReward(LoyaltyReward reward) async {
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
            points: -reward.pointsCost,
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
    if (_useDemoData || service == null || !isInternalAdmin) return;
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

  Future<bool> adjustLoyaltyPoints({
    required String userId,
    required int points,
    required String reason,
  }) async {
    final service = _coreBackend;
    if (service == null || !isInternalAdmin) return false;
    try {
      await service.adjustLoyaltyPoints(
        userId: userId,
        points: points,
        reason: reason,
      );
      await refreshLoyaltyBalances();
      toasts.show(
        ToastMessage.success(
          '${points > 0 ? '+' : ''}$points points — $reason',
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

  Future<bool> saveLoyaltyReward({
    String? id,
    required String name,
    String description = '',
    required int pointsCost,
    bool active = true,
    int? stock,
  }) async {
    final service = _coreBackend;
    if (service == null || !isInternalAdmin) return false;
    try {
      await service.saveLoyaltyReward(
        id: id,
        name: name,
        description: description,
        pointsCost: pointsCost,
        active: active,
        stock: stock,
      );
      showToast(
        ToastMessage.success(id == null ? 'Reward created.' : 'Reward saved.'),
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

  Future<bool> setLoyaltyRewardActive(String rewardId, bool active) async {
    final service = _coreBackend;
    if (service == null || !isInternalAdmin) return false;
    try {
      await service.setLoyaltyRewardActive(rewardId, active);
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
    List<String> amenities = const [],
  }) async {
    final service = _coreBackend;
    if (service == null || _useDemoData || !hasSession) {
      final duration = startsAt.isEmpty || endsAt.isEmpty
          ? 0.0
          : endsAt.first.difference(startsAt.first).inMinutes / 60;
      final exempt = userAccount.isPaymentExempt;
      final total = exempt ? 0 : quoteFor(facility, duration) * 100;
      final percent = facility.downPaymentPercent;
      return BackendReservationQuote(
        facilityId: facility.id,
        audience: userAccount.pricingAudience,
        adminLane: userAccount.verification == VerificationState.verified
            ? 'internal'
            : 'external',
        facilityAmountCentavos: total,
        amenityAmountCentavos: 0,
        discountAmountCentavos: 0,
        totalAmountCentavos: total,
        requiredDownPaymentCentavos: (total * percent + 99) ~/ 100,
        pricingFingerprint: 'demo',
        lines: const [],
        terms: const [],
        downPaymentPercent: percent,
        paymentExemption: switch (userAccount.pricingAudience) {
          'student' when exempt => 'verified_student',
          'faculty' when exempt => 'verified_faculty',
          _ => 'none',
        },
      );
    }
    final selected = {
      for (final label in amenities)
        for (final option in facility.amenityOptions)
          if (option.name == label) option.id,
    }.toList();
    try {
      return await service.reservationQuote(
        facilityId: facility.id,
        startsAt: startsAt,
        endsAt: endsAt,
        headcount: headcount ?? 1,
        amenityIds: selected,
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
    List<String> amenities = const [],
    BackendReservationQuote? quote,
    bool acceptedTerms = false,
  }) async {
    final service = backend;
    if (_useDemoData || service == null || !hasSession) {
      submitBooking(
        facility: facility,
        date: formatCampusDate(campusWallTime(startsAt.first)),
        start: _clock(campusWallTime(startsAt.first)),
        end: _clock(campusWallTime(endsAt.first)),
        heads: heads,
        purpose: purpose,
        amenities: amenities,
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
            amenities: amenities,
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
      final amenityIds = {
        for (final label in amenities)
          for (final option in facility.amenityOptions)
            if (option.name == label) option.id,
      }.toList();
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
          amenities: amenities,
          amenityIds: amenityIds,
          termsVersionIds: [
            for (final term
                in authoritativeQuote?.terms ?? const <BackendTermsVersion>[])
              term.id,
          ],
          pricingFingerprint: core == null
              ? null
              : authoritativeQuote!.pricingFingerprint,
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
      showToast(
        const ToastMessage('GCash proof submitted for administrator review.'),
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

  Future<void> uploadPermitPdf({
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
        requestId: requestId,
        requesterId: requesterId,
        permitNumber: permitNumber,
        version: version,
        bytes: bytes,
      );
    } catch (_) {}
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

  Future<List<FacilityAssignmentOption>> facilityAssignmentDirectory(
    String facilityId,
  ) async {
    final service = _coreBackend;
    if (service == null) return const [];
    try {
      return await service.facilityAssignmentDirectory(facilityId);
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return const [];
    }
  }

  Future<bool> setFacilityAssignment({
    required String facilityId,
    required String adminId,
    required String assignmentRole,
  }) async {
    final service = _coreBackend;
    if (service == null) return false;
    try {
      await service.setFacilityAssignment(
        facilityId: facilityId,
        adminId: adminId,
        assignmentRole: assignmentRole,
      );
      await refreshFacilities();
      return true;
    } catch (error) {
      showToast(
        ToastMessage(_reservationError(error), tone: AdvisoryTone.block),
      );
      return false;
    }
  }

  Future<bool> removeFacilityAssignment({
    required String facilityId,
    required String adminId,
  }) async {
    final service = _coreBackend;
    if (service == null) return false;
    try {
      await service.removeFacilityAssignment(
        facilityId: facilityId,
        adminId: adminId,
      );
      await refreshFacilities();
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
    if (targets.isEmpty) return {};
    final keys = _busyKeysFor(targets, fromWall, toWall);
    final now = DateTime.now();
    final allCached = keys.every((key) {
      final cachedAt = _busyCacheAt[key];
      return cachedAt != null && now.difference(cachedAt) < _busyCacheTtl;
    });
    if (allCached) {
      return {for (final key in keys) key: _busyCache[key] ?? const []};
    }

    var byKey = <String, List<BusyWindow>>{for (final key in keys) key: []};
    final service = backend;
    if (!_useDemoData && service != null && hasSession) {
      try {
        final ids = {for (final facility in targets) facility.id}.toList();
        final rows = await service.facilityBusyWindows(
          facilityIds: ids,
          from: campusInstant(fromWall),
          to: campusInstant(toWall),
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
        _addOwnRequestsToBusyMap(targets, byKey);
        busyWindowsDegraded = false;
      } catch (_) {
        busyWindowsDegraded = true;
        byKey = _localBusyWindows(targets, fromWall, toWall);
      }
    } else {
      byKey = _localBusyWindows(targets, fromWall, toWall);
    }

    final stamped = now;
    for (final entry in byKey.entries) {
      _busyCache[entry.key] = entry.value;
      _busyCacheAt[entry.key] = stamped;
    }
    return {for (final key in keys) key: byKey[key] ?? const []};
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
        if (occurrence.bookingState == 'cancelled' ||
            occurrence.bookingState == 'expired') {
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
