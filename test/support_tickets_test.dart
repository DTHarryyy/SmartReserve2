import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/app/app_view.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/support/support_page.dart';
import 'package:smartreserve/features/support/support_screen.dart';
import 'package:smartreserve/model/notification_navigation.dart';
import 'package:smartreserve/model/support_ticket.dart';
import 'package:smartreserve/theme/sr_theme.dart';

SessionProfile _profile(String role) => SessionProfile(
  id: role == 'user' ? 'renter-1' : 'admin-1',
  email: '$role@example.test',
  fullName: role == 'user' ? 'Jamie Renter' : 'Ada Admin',
  role: role,
  campusClaim: null,
  campusId: null,
  unit: null,
  verificationStatus: 'none',
  onboardingComplete: true,
  accountStatus: 'active',
  accountAccessType: role == 'user' ? 'external_guest' : 'administrator',
  mustChangePassword: false,
  createdAt: null,
);

SupportTicket _ticket({
  String id = 't-1',
  SupportStatus status = SupportStatus.open,
  List<SupportReply> replies = const [],
}) => SupportTicket(
  id: id,
  requesterId: 'renter-1',
  requesterName: 'Jamie Renter',
  requesterEmail: 'user@example.test',
  category: SupportCategory.payment,
  subject: 'GCash proof will not upload',
  message: 'The upload spins forever on my phone.',
  status: status,
  createdAt: DateTime.utc(2026, 10, 20, 2),
  lastActivityAt: DateTime.utc(2026, 10, 20, 2),
  replies: replies,
);

class _Backend implements SmartReserveBackend {
  List<SupportTicket> tickets = [_ticket()];
  final replies = <(String, String)>[];
  final statuses = <(String, SupportStatus)>[];
  SupportTicketDraft? created;

  @override
  Future<List<SupportTicket>> supportTickets() async => tickets;

  @override
  Future<SupportTicket> createSupportTicket(
    SupportTicketDraft draft, {
    ReservationUpload? attachment,
  }) async {
    created = draft;
    final ticket = _ticket(id: 't-new');
    tickets = [ticket, ...tickets];
    return ticket;
  }

  @override
  Future<void> replySupportTicket(String ticketId, String message) async {
    replies.add((ticketId, message));
  }

  @override
  Future<void> setSupportTicketStatus(
    String ticketId,
    SupportStatus status,
  ) async {
    statuses.add((ticketId, status));
    tickets = [
      for (final ticket in tickets)
        ticket.id == ticketId ? _ticket(id: ticket.id, status: status) : ticket,
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected call: ${invocation.memberName}');
}

class _State extends AppState {
  _State() : super(useDemoData: false);

  @override
  bool get hasSession => true;
}

Future<void> _pump(WidgetTester tester, AppState state, Widget home) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: MaterialApp(
        theme: SrThemeData.light(),
        builder: (context, child) =>
            SrThemeBridge(child: child ?? const SizedBox.shrink()),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('drafts enforce the database length limits', () {
    expect(
      const SupportTicketDraft(
        category: SupportCategory.bug,
        subject: 'Hi',
        message: 'Long enough message here',
      ).error,
      contains('subject'),
    );
    expect(
      const SupportTicketDraft(
        category: SupportCategory.bug,
        subject: 'Calendar blank',
        message: 'short',
      ).error,
      contains('Describe'),
    );
    expect(
      const SupportTicketDraft(
        category: SupportCategory.bug,
        subject: 'Calendar blank',
        message: 'The calendar shows nothing.',
      ).error,
      isNull,
    );
  });

  test('a ticket awaits an admin until an admin has the last word', () {
    expect(_ticket().awaitingAdmin, isTrue);
    final answered = _ticket(
      replies: [
        SupportReply(
          id: 'r-1',
          authorName: 'Ada',
          fromAdmin: true,
          message: 'Try again',
          createdAt: DateTime.utc(2026, 10, 20, 3),
        ),
      ],
    );
    expect(answered.awaitingAdmin, isFalse);
    expect(_ticket(status: SupportStatus.resolved).awaitingAdmin, isFalse);
  });

  test('support notifications open the ticket for both audiences', () {
    for (final admin in [true, false]) {
      final intent = resolveNotificationNavigation(
        kind: 'support_reply',
        isAdmin: admin,
        supportTicketId: 't-1',
      );
      expect(intent.destination, NotificationDestination.support);
      expect(intent.resourceId, 't-1');
    }
  });

  testWidgets('a renter files a ticket and replies in the thread', (
    tester,
  ) async {
    final backend = _Backend()..tickets = [];
    final state = _State()
      ..backend = backend
      ..sessionProfile = _profile('user');

    await _pump(tester, state, const SupportPage());
    expect(find.text('You have not contacted support yet.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('support-new-ticket')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('support-submit')));
    await tester.pump();
    expect(find.byKey(const Key('support-error')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('support-subject')),
      'GCash proof will not upload',
    );
    await tester.enterText(
      find.byKey(const Key('support-message')),
      'The upload spins forever on my phone.',
    );
    await tester.tap(find.byKey(const Key('support-submit')));
    await tester.pumpAndSettle();

    expect(backend.created?.subject, 'GCash proof will not upload');
    // The new ticket opens straight away.
    expect(find.byKey(const Key('support-reply-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('support-reply-field')),
      'It also fails on Wi-Fi.',
    );
    await tester.tap(find.byKey(const Key('support-reply-send')));
    await tester.pumpAndSettle();
    expect(backend.replies.single, ('t-new', 'It also fails on Wi-Fi.'));
    // Renters cannot resolve their own ticket.
    expect(find.byKey(const Key('support-status-resolved')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an admin opens a ticket from the queue and resolves it', (
    tester,
  ) async {
    final backend = _Backend();
    final state = _State()
      ..backend = backend
      ..sessionProfile = _profile('internal_admin');
    await state.refreshSupportTickets();

    await _pump(tester, state, const Scaffold(body: SupportScreen()));
    expect(find.text('GCash proof will not upload'), findsOneWidget);
    expect(state.supportAwaitingCount, 1);

    await tester.tap(find.byKey(const ValueKey('support-ticket-t-1')));
    await tester.pumpAndSettle();
    expect(find.text('The upload spins forever on my phone.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('support-status-resolved')));
    await tester.pumpAndSettle();
    expect(backend.statuses.single, ('t-1', SupportStatus.resolved));
    expect(state.supportTicketById('t-1')?.status, SupportStatus.resolved);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  test('opening a support notification as admin selects the ticket', () async {
    final backend = _Backend();
    final state = _State()
      ..backend = backend
      ..sessionProfile = _profile('internal_admin')
      ..view = AppView.dashboard;

    await state.openNotification(
      BackendNotification(
        id: 'n-1',
        kind: 'support_ticket_new',
        title: 'New support ticket',
        body: 'Jamie Renter: GCash proof will not upload',
        createdAt: DateTime.utc(2026, 10, 20, 2),
        supportTicketId: 't-1',
        readAt: DateTime.utc(2026, 10, 20, 3),
      ),
    );
    expect(state.view, AppView.support);
    expect(state.selectedSupportTicketId, 't-1');
  });
}
