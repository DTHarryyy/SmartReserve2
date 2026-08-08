import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../features/add_facility/add_facility_actions.dart';
import '../features/add_facility/add_facility_controller.dart';
import '../features/add_facility/add_facility_screen.dart';
import '../features/audit/audit_screen.dart';
import '../features/auth/auth_controller.dart';
import '../features/auth/auth_screen.dart';
import '../features/calendar/calendar_screen.dart';
import '../features/facilities/facilities_screen.dart';
import '../features/notes/notes_screen.dart';
import '../features/reports/reports_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/reservations/reservations_screen.dart';
import '../features/student/student_app.dart';
import '../features/users/users_screen.dart';
import '../features/users/invite_dialog.dart';
import '../features/verifications/verifications_screen.dart';
import '../model/facility.dart';
import '../model/reservation.dart';
import '../theme/sr_tokens.dart';
import '../widgets/app_header.dart';
import '../widgets/notices.dart';
import '../widgets/side_nav.dart';
import '../widgets/sr_controls.dart';
import 'app_scope.dart';
import 'app_state.dart';
import 'app_view.dart';
import 'demo_states.dart';

enum Layout {
  desktop,

  tablet,

  mobile;

  static Layout of(double width) {
    if (width >= SR.desktopMin) return Layout.desktop;
    if (width >= SR.tabletMin) return Layout.tablet;
    return Layout.mobile;
  }

  bool get isDesktop => this == Layout.desktop;
  bool get isMobile => this == Layout.mobile;

  bool get compact => this != Layout.desktop;
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  final AddFacilityController _addFacility = AddFacilityController();

  AuthController? _auth;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _addFacility.addListener(_onFacilityControllerChanged);
  }

  void _onFacilityControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final state = AppScope.read(context);
    _auth ??= AuthController(state);
    _addFacility.toastSink = (message, duration) =>
        state.showToast(message, duration: duration);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _addFacility.removeListener(_onFacilityControllerChanged);
    _addFacility.dispose();
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
    if (event.logicalKey == LogicalKeyboardKey.keyU && state.undo != null) {
      state.takeUndo();
      return true;
    }
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

    if (!state.view.usesAdminChrome) {
      return Scaffold(
        backgroundColor: SR.bg,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: state.view == AppView.studentApp
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
      backgroundColor: SR.bg,
      drawer: layout.isDesktop
          ? null
          : Drawer(
              backgroundColor: SR.navBg,
              width: SideNav.width,
              child: SideNav(state: state, onSelect: _navSelect),
            ),
      floatingActionButton:
          layout.isMobile &&
              state.view == AppView.users &&
              state.isInternalAdmin
          ? FloatingActionButton(
              key: const Key('invite-admin-fab'),
              tooltip: 'Invite administrator',
              backgroundColor: SR.blue,
              foregroundColor: SR.surface,
              onPressed: () => showInviteDialog(context, state),
              child: const Icon(Icons.add_rounded),
            )
          : null,
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
              crumbs: _editingFacility(state)
                  ? const ['Facilities', 'Edit facility']
                  : state.view.breadcrumbs,
              title: _editingFacility(state)
                  ? (_addFacility.draft.name.trim().isEmpty
                        ? 'Edit facility'
                        : _addFacility.draft.name.trim())
                  : state.view.title,
              compact: !layout.isDesktop,
              avatarInitials: state.currentAdmin.initials,
              onToggleStates: state.toggleStates,
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
    if (state.statesOpen) ...[
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: state.closeOverlays,
        ),
      ),
      Positioned(
        right: 24,

        top: layout.isDesktop ? 68 : 60,
        child: DemoStatesMenu(state: state),
      ),
    ],
    if (state.notificationsOpen) ...[
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: state.closeOverlays,
        ),
      ),
      Positioned(
        right: 24,
        top: layout.isDesktop ? 68 : 60,
        child: _NotificationsPanel(state: state),
      ),
    ],

    if (state.view == AppView.addFacility && _addFacility.showErrorBar)
      Positioned(
        left: 16,
        right: 16,
        bottom: layout.isMobile ? 84 : 22,
        child: ErrorBar(
          text: _addFacility.errorBarText,
          onJumpToFirst: () => jumpToFirstIssue(_addFacility),
          onDismiss: _addFacility.dismissErrorBar,
        ),
      ),

    if (state.undo case final offer?)
      Positioned(
        left: 22,
        right: 22,
        bottom: layout.isMobile ? 84 : 22,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: UndoBar(
            offer: offer,
            onUndo: state.takeUndo,
            onDismiss: state.dismissUndo,
          ),
        ),
      ),

    if (state.toast case final toast?)
      Positioned(
        right: 22,
        left: layout.isMobile ? 22 : null,
        bottom: layout.isMobile ? 84 : (state.undo == null ? 22 : 76),
        child: Align(
          alignment: Alignment.bottomRight,
          child: SrToast(message: toast),
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
                    color: SR.surface.withValues(alpha: .6),
                  ),
                )
              : null,
        ),
      ],
      AppView.facilities => [
        SrButton(
          label: '＋ New facility',
          kind: SrButtonKind.primary,
          onPressed: () => _openEditor(state, null),
        ),
      ],
      _ => const [],
    },
  ];

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
      onFixLocation: (facility) => _openEditor(state, facility),
    ),
    AppView.users => const UsersScreen(),
    AppView.audit => const AuditScreen(),
    AppView.notes => const NotesScreen(),
    AppView.profile => const ProfileScreen(),

    AppView.studentApp || AppView.auth => const SizedBox.shrink(),
  };

  void _openEditor(AppState state, Facility? facility) {
    _addFacility.availableFacilities = state.facilities;
    if (facility == null) {
      _addFacility.startNewRecord();
    } else {
      _addFacility.loadForEditing(facility);
    }
    state.goTo(AppView.addFacility);
  }
}

class _NotificationsPanel extends StatelessWidget {
  const _NotificationsPanel({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Container(
      width: 360,
      constraints: const BoxConstraints(maxHeight: 480),
      decoration: BoxDecoration(
        color: SR.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SR.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 11),
            child: Text('Notifications', style: sans(14, w: 600)),
          ),
          const Divider(height: 1, color: SR.border),
          if (state.notificationsError case final error?)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(error, style: sans(11.5, color: SR.red)),
            )
          else if (state.notifications.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No notifications yet.',
                textAlign: TextAlign.center,
                style: sans(12, color: SR.muted),
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: state.notifications.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: SR.hairline),
                itemBuilder: (context, index) {
                  final item = state.notifications[index];
                  return InkWell(
                    onTap: () {
                      state.closeOverlays();
                      state.openNotification(item);
                    },
                    child: Container(
                      color: item.unread ? SR.blueTint : SR.surface,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            style: sans(12, w: item.unread ? 600 : 500),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            item.body,
                            style: sans(11, height: 1.45, color: SR.ink4),
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
