import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/add_facility/add_facility_actions.dart';
import '../features/add_facility/add_facility_controller.dart';
import '../features/add_facility/facility_editor_focus.dart';
import '../features/add_facility/add_facility_screen.dart';
import '../features/anomalies/anomalies_screen.dart';
import '../features/audit/audit_screen.dart';
import '../features/auth/auth_controller.dart';
import '../features/auth/auth_screen.dart';
import '../features/calendar/calendar_screen.dart';
import '../features/facilities/facilities_screen.dart';
import '../features/feedback/feedback_screen.dart';
import '../features/loyalty/loyalty_admin_screen.dart';
import '../features/notes/notes_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/reports/reports_screen.dart';
import '../features/reports/reports_data.dart';
import '../features/reservations/reservations_screen.dart';
import '../features/student/student_app.dart';
import '../features/users/users_screen.dart';
import '../features/users/invite_dialog.dart';
import '../features/verifications/verifications_screen.dart';
import '../model/facility.dart';
import '../model/reservation.dart';
import '../theme/sr_theme.dart';
import '../theme/sr_tokens.dart';
import '../widgets/app_header.dart';
import '../widgets/notices.dart';
import '../widgets/side_nav.dart';
import '../widgets/sr_controls.dart';
import 'app_scope.dart';
import 'app_state.dart';
import 'app_view.dart';

enum Layout {
  desktop,

  tablet,

  mobile;

  static Layout of(double width) => switch (SrBreakpoint.of(width)) {
    SrBreakpoint.large => Layout.desktop,
    SrBreakpoint.expanded || SrBreakpoint.medium => Layout.tablet,
    SrBreakpoint.compact => Layout.mobile,
  };

  bool get isDesktop => this == Layout.desktop;
  bool get isMobile => this == Layout.mobile;

  bool get belowDesktop => this != Layout.desktop;
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  late final AddFacilityController _addFacility;
  var _facilityControllerReady = false;

  AuthController? _auth;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  void _onFacilityControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final state = AppScope.read(context);
    _auth ??= AuthController(state);
    if (!_facilityControllerReady) {
      _addFacility = AddFacilityController(toasts: state.toasts)
        ..addListener(_onFacilityControllerChanged);
      _facilityControllerReady = true;
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (_facilityControllerReady) {
      _addFacility.removeListener(_onFacilityControllerChanged);
      _addFacility.dispose();
    }
    _auth?.dispose();
    super.dispose();
  }

  AppState get _state => AppScope.read(context);

  bool get _typing {
    final focus = FocusManager.instance.primaryFocus;
    return focus?.context?.widget is EditableText ||
        focus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final keys = HardwareKeyboard.instance;
    final accel = keys.isControlPressed || keys.isMetaPressed;
    final state = _state;

    if (accel && event.logicalKey == LogicalKeyboardKey.keyS) {
      if (state.view == AppView.addFacility) {
        saveFacility(context, state, _addFacility);
      }
      return true;
    }
    if (accel && event.logicalKey == LogicalKeyboardKey.keyK) {
      if (state.view == AppView.addFacility) _addFacility.openSearch();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      state.closeOverlays();
      if (_addFacility.fullscreenMap) {
        _addFacility.setFullscreenMap(false);
      } else {
        _addFacility
          ..closeSearch()
          ..closeAmenities();
      }
      return true;
    }
    if (_typing) return false;
    return _onScreenKey(event, state);
  }

  bool _onScreenKey(KeyEvent event, AppState state) {
    if (state.view != AppView.reservations) return false;

    if (event.logicalKey == LogicalKeyboardKey.keyJ) {
      state.stepRequestSelection(1);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyK) {
      state.stepRequestSelection(-1);
      return true;
    }
    final selected = state.selectedRequest;
    if (selected == null || !selected.isPending) return false;
    if (event.logicalKey == LogicalKeyboardKey.keyA) {
      state.decideRequest(selected.id, RequestStatus.approved);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyD) {
      state.showToast(
        const ToastMessage(
          'Declining needs a reason — use the Decline button in the panel.',
          tone: AdvisoryTone.info,
        ),
      );
      return true;
    }
    return false;
  }

  void _navSelect(AppView section) {
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
    _state.goTo(section);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final layout = Layout.of(MediaQuery.sizeOf(context).width);

    return PrimaryScrollController.none(child: _scaffold(state, layout));
  }

  Widget _scaffold(AppState state, Layout layout) {
    if (!state.view.usesAdminChrome) {
      return Scaffold(
        backgroundColor: context.srColors.bg,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: state.view == AppView.userApp
                    ? const StudentApp()
                    : AuthScreen(controller: _auth!, state: state),
              ),
              ..._overlays(state, layout),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: context.srColors.bg,
      drawer: layout.isDesktop
          ? null
          : Drawer(
              backgroundColor: context.srColors.navBg,
              width: SideNav.width,
              child: SideNav(state: state, onSelect: _navSelect),
            ),
      floatingActionButton: layout.isMobile ? _mobileAction(state) : null,
      body: SafeArea(
        child: Row(
          children: [
            if (layout.isDesktop) SideNav(state: state, onSelect: _navSelect),
            Expanded(child: _chrome(state, layout)),
          ],
        ),
      ),
    );
  }

  Widget _chrome(AppState state, Layout layout) => Stack(
    children: [
      Positioned.fill(
        child: Column(
          children: [
            AppHeader(
              crumbs: state.isExternalAdmin && state.view == AppView.users
                  ? const ['Clients']
                  : _editingFacility(state)
                  ? const ['Facilities', 'Edit facility']
                  : state.view.breadcrumbs,
              title: state.isExternalAdmin && state.view == AppView.users
                  ? 'Clients'
                  : _editingFacility(state)
                  ? (_addFacility.draft.name.trim().isEmpty
                        ? 'Edit facility'
                        : _addFacility.draft.name.trim())
                  : state.view.title,
              compact: !layout.isDesktop,
              mobile: layout.isMobile,
              avatarInitials: state.currentAdmin.initials,
              onOpenProfile: () => state.goTo(AppView.profile),
              onMenu: layout.isDesktop
                  ? null
                  : () => _scaffoldKey.currentState?.openDrawer(),
              chip: _headerChip(state),
              actions: _headerActions(state, layout),
            ),
            Expanded(child: _body(state, layout)),
          ],
        ),
      ),

      ..._overlays(state, layout),
    ],
  );

  List<Widget> _overlays(AppState state, Layout layout) => [
    if (state.notificationsOpen) ...[
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: state.closeOverlays,
        ),
      ),
      Positioned(
        right: layout.isMobile ? 12 : 24,
        left: layout.isMobile ? 12 : null,
        top: layout.isDesktop ? 68 : 60,
        child: Align(
          alignment: Alignment.topRight,
          child: _NotificationsPanel(state: state),
        ),
      ),
    ],

    if (state.view == AppView.addFacility && _addFacility.showErrorBar)
      Positioned(
        left: 16,
        right: 16,
        bottom: layout.isMobile && state.view == AppView.addFacility ? 84 : 22,
        child: ErrorBar(
          text: _addFacility.errorBarText,
          onJumpToFirst: () => jumpToFirstIssue(_addFacility),
          onDismiss: _addFacility.dismissErrorBar,
        ),
      ),
  ];

  bool _editingFacility(AppState state) =>
      state.view == AppView.addFacility && _addFacility.editingId != null;

  Widget? _headerChip(AppState state) {
    if (state.view != AppView.addFacility) return null;
    final label = _addFacility.draftChipLabel;
    return label == null ? null : HeaderChip(label: label);
  }

  List<Widget> _headerActions(AppState state, Layout layout) => [
    if (layout.isMobile)
      SrIconButton(
        icon: Icons.notifications_none_rounded,
        tooltip: state.unreadNotifications == 0
            ? 'Notifications'
            : '${state.unreadNotifications} unread notifications',
        size: 40,
        onPressed: state.toggleNotifications,
      )
    else
      SrButton(
        label: state.unreadNotifications == 0
            ? 'Notifications'
            : 'Notifications ${state.unreadNotifications}',
        dense: true,
        onPressed: state.toggleNotifications,
      ),
    ...switch (state.view) {
      AppView.addFacility when !layout.isMobile => [
        SrButton(
          label: 'Cancel',
          dense: true,
          onPressed: () => cancelEdit(context, state, _addFacility),
        ),
        SrButton(
          label: _addFacility.saving
              ? 'Saving…'
              : (_addFacility.editingId == null
                    ? 'Save facility'
                    : 'Save changes'),
          kind: SrButtonKind.primary,
          onPressed: _addFacility.saving
              ? null
              : () => saveFacility(context, state, _addFacility),
          trailing: layout.isDesktop
              ? Text(
                  '⌘S',
                  style: mono(
                    10,
                    w: 500,
                    color: context.srColors.surface.withValues(alpha: .6),
                  ),
                )
              : null,
        ),
      ],
      AppView.facilities when !layout.isMobile && state.isAdmin => [
        SrButton(
          label: 'New facility',
          icon: const Icon(
            Icons.add_rounded,
            size: SR.iconMd,
            color: SR.onDark,
          ),
          kind: SrButtonKind.primary,
          onPressed: () => _openEditor(state, null),
        ),
      ],
      _ => const [],
    },
  ];

  Widget? _mobileAction(AppState state) => switch (state.view) {
    AppView.facilities when state.isAdmin => FloatingActionButton.extended(
      key: const Key('add-facility-fab'),
      tooltip: 'Add facility',
      backgroundColor: SR.primary,
      foregroundColor: context.srColors.surface,
      onPressed: () => _openEditor(state, null),
      icon: const Icon(Icons.add_rounded),
      label: const Text('Facility'),
    ),
    AppView.users when state.isInternalAdmin => FloatingActionButton.extended(
      key: const Key('invite-admin-fab'),
      tooltip: 'Invite administrator',
      backgroundColor: SR.primary,
      foregroundColor: SR.onDark,
      onPressed: () => showInviteDialog(context, state),
      icon: const Icon(Icons.person_add_alt_1_rounded),
      label: const Text('Invite'),
    ),
    _ => null,
  };

  Widget _body(AppState state, Layout layout) => switch (state.view) {
    AppView.addFacility => AddFacilityBody(
      controller: _addFacility,
      layout: layout,
      onSave: () => saveFacility(context, state, _addFacility),
      onBackToList: () => state.goTo(AppView.facilities),
    ),
    AppView.facilities => FacilitiesScreen(
      onEdit: (facility) => _openEditor(state, facility),
    ),
    AppView.reservations => const ReservationsScreen(),
    AppView.calendar => const CalendarScreen(),
    AppView.verifications => const VerificationsScreen(),
    AppView.reports => ReportsScreen(
      onResolveQualityIssue: state.isAdmin
          ? (issue) => _openEditor(
              state,
              issue.facility,
              focus: issue.focus,
              reason: _qualityReason(issue),
            )
          : null,
    ),
    AppView.users => const UsersScreen(),
    AppView.feedback => const FeedbackScreen(),
    AppView.anomalies => const AnomaliesScreen(),
    AppView.loyalty => const LoyaltyAdminScreen(),
    AppView.audit => const AuditScreen(),
    AppView.notes => const NotesScreen(),
    AppView.profile => const ProfileScreen(),

    AppView.userApp || AppView.auth => const SizedBox.shrink(),
  };

  void _openEditor(
    AppState state,
    Facility? facility, {
    FacilityEditorFocus? focus,
    FacilityEditorReason? reason,
  }) {
    _addFacility.availableFacilities = state.facilities;
    if (facility == null) {
      _addFacility.startNewRecord();
    } else {
      _addFacility.loadForEditing(facility, reason: reason);
      _addFacility.focusEditorSection(focus, reason: reason);
    }
    state.goTo(AppView.addFacility);
  }

  FacilityEditorReason _qualityReason(QualityIssue issue) =>
      switch (issue.type) {
        QualityIssueType.missingPin => FacilityEditorReason.missingPin,
        QualityIssueType.pinOutsideCampus => FacilityEditorReason.outsideCampus,
        QualityIssueType.unverifiedPin => FacilityEditorReason.unverifiedPin,
        QualityIssueType.lowCoordinateAccuracy =>
          FacilityEditorReason.lowCoordinateAccuracy,
        QualityIssueType.missingPhotos => FacilityEditorReason.photos,
      };
}

class _NotificationsPanel extends StatelessWidget {
  const _NotificationsPanel({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final colors = context.srColors;
    final availableHeight = (MediaQuery.sizeOf(context).height - 76).clamp(
      160.0,
      480.0,
    );
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 360,
        constraints: BoxConstraints(maxHeight: availableHeight),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(SR.rMd),
          border: Border.all(color: colors.border),
          boxShadow: SR.popoverShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SR.space16,
                SR.space12,
                SR.space16,
                SR.space12,
              ),
              child: Text('Notifications', style: SrType.subhead()),
            ),
            Divider(height: 1, color: colors.border),
            if (state.notificationsError case final error?)
              Padding(
                padding: const EdgeInsets.all(SR.space16),
                child: Text(error, style: SrType.bodySm(color: colors.red)),
              )
            else if (state.notifications.isEmpty)
              Padding(
                padding: const EdgeInsets.all(SR.space24),
                child: Text(
                  'No notifications yet.',
                  textAlign: TextAlign.center,
                  style: SrType.bodySm(color: colors.muted),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: state.notifications.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: colors.hairline),
                  itemBuilder: (context, index) {
                    final item = state.notifications[index];
                    return InkWell(
                      onTap: () {
                        state.closeOverlays();
                        state.openNotification(item);
                      },
                      child: Container(
                        color: item.unread
                            ? colors.primaryTint2
                            : colors.surface,
                        padding: const EdgeInsets.symmetric(
                          horizontal: SR.space16,
                          vertical: SR.space12,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(
                                top: SR.space6,
                                right: SR.space8,
                              ),
                              child: Container(
                                width: SR.space6,
                                height: SR.space6,
                                decoration: BoxDecoration(
                                  color: item.unread
                                      ? SR.primary
                                      : Colors.transparent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title,
                                    style: SrType.bodySm(
                                      w: item.unread ? 600 : 500,
                                      color: colors.ink,
                                    ),
                                  ),
                                  const SizedBox(height: SR.space2),
                                  Text(item.body, style: SrType.caption()),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
