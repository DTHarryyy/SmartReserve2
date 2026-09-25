import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/reservations/permit_panel.dart';
import 'package:smartreserve/model/permit.dart';
import 'package:smartreserve/model/reservation.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/widgets/signature_pad.dart';
import 'package:smartreserve/widgets/sr_controls.dart';

class _ReadinessState extends AppState {
  _ReadinessState(this.readiness);

  final PermitReadiness readiness;

  @override
  Future<PermitReadiness?> permitReadiness(String requestId) async => readiness;
}

void main() {
  testWidgets('missing signature gives the administrator a request action', (
    tester,
  ) async {
    final state =
        _ReadinessState(
            const PermitReadiness(
              ready: false,
              templateKind: PermitTemplateKind.internal,
              blockerCodes: ['requester_signature_required'],
              requesterSignatureState: PermitRequesterSignatureState.missing,
            ),
          )
          ..sessionProfile = SessionProfile(
            id: 'admin-session-id',
            email: 'admin@csu.edu.ph',
            fullName: 'CSU Administrator',
            role: 'internal_admin',
            campusClaim: null,
            campusId: null,
            unit: null,
            verificationStatus: 'verified',
            onboardingComplete: true,
            accountStatus: 'active',
            accountAccessType: 'legacy_unassigned',
            mustChangePassword: false,
            createdAt: DateTime.utc(2026),
          );
    final request = ReservationRequest(
      id: 'reservation-id',
      requesterId: 'u1',
      facility: 'Gymplex',
      building: 'Main campus',
      room: 'Gymnasium',
      capacity: 100,
      requester: 'Requester',
      role: 'Student',
      org: 'CICS',
      purpose: 'Event',
      date: '25 September 2026',
      start: '11:00',
      end: '13:00',
      heads: 5,
      submitted: 'Just now',
      urgent: false,
      attachments: 0,
      noShows: 0,
      status: RequestStatus.approved,
      lifecycleStatus: ReservationLifecycleStatus.confirmed,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: SrThemeData.dark(),
        home: Scaffold(
          body: PermitPanel(state: state, request: request),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Request signature'), findsOneWidget);
    expect(find.text('Request updated signature'), findsNothing);
    expect(find.textContaining('Your e-signature is recorded'), findsNothing);
  });

  testWidgets(
    'stale signature is never presented as current to an administrator',
    (tester) async {
      final state =
          _ReadinessState(
              const PermitReadiness(
                ready: false,
                templateKind: PermitTemplateKind.internal,
                blockerCodes: ['requester_signature_required'],
                requesterSignatureState: PermitRequesterSignatureState.stale,
              ),
            )
            ..sessionProfile = SessionProfile(
              id: 'admin-session-id',
              email: 'admin@csu.edu.ph',
              fullName: 'CSU Administrator',
              role: 'internal_admin',
              campusClaim: null,
              campusId: null,
              unit: null,
              verificationStatus: 'verified',
              onboardingComplete: true,
              accountStatus: 'active',
              accountAccessType: 'legacy_unassigned',
              mustChangePassword: false,
              createdAt: DateTime.utc(2026),
            );
      final request = ReservationRequest(
        id: 'reservation-id',
        requesterId: 'u1',
        facility: 'Gymplex',
        building: 'Main campus',
        room: 'Gymnasium',
        capacity: 100,
        requester: 'Requester',
        role: 'Student',
        org: 'CICS',
        purpose: 'Event',
        date: '25 September 2026',
        start: '11:00',
        end: '13:00',
        heads: 5,
        submitted: 'Just now',
        urgent: false,
        attachments: 0,
        noShows: 0,
        status: RequestStatus.approved,
        lifecycleStatus: ReservationLifecycleStatus.confirmed,
        signatureRequestId: 'old-signature-request',
        signatureRequestStatus: 'signed',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SrThemeData.dark(),
          home: Scaffold(
            body: PermitPanel(state: state, request: request),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('no longer matches the current reservation'),
        findsOneWidget,
      );
      expect(find.textContaining('Your e-signature is recorded'), findsNothing);
      expect(
        find.textContaining('must sign the updated reservation details'),
        findsOneWidget,
      );
      expect(find.text('Request updated signature'), findsOneWidget);
    },
  );

  testWidgets('requester sees that a stale signature needs a new request', (
    tester,
  ) async {
    final state =
        _ReadinessState(
            const PermitReadiness(
              ready: false,
              templateKind: PermitTemplateKind.internal,
              blockerCodes: ['requester_signature_required'],
              requesterSignatureState: PermitRequesterSignatureState.stale,
            ),
          )
          ..sessionProfile = SessionProfile(
            id: 'u1',
            email: 'requester@csu.edu.ph',
            fullName: 'Requester',
            role: 'user',
            campusClaim: null,
            campusId: null,
            unit: null,
            verificationStatus: 'verified',
            onboardingComplete: true,
            accountStatus: 'active',
            accountAccessType: 'legacy_unassigned',
            mustChangePassword: false,
            createdAt: DateTime.utc(2026),
          );
    final request = ReservationRequest(
      id: 'reservation-id',
      requesterId: 'u1',
      facility: 'Gymplex',
      building: 'Main campus',
      room: 'Gymnasium',
      capacity: 100,
      requester: 'Requester',
      role: 'Student',
      org: 'CICS',
      purpose: 'Event',
      date: '25 September 2026',
      start: '11:00',
      end: '13:00',
      heads: 5,
      submitted: 'Just now',
      urgent: false,
      attachments: 0,
      noShows: 0,
      status: RequestStatus.approved,
      lifecycleStatus: ReservationLifecycleStatus.confirmed,
      signatureRequestId: 'old-signature-request',
      signatureRequestStatus: 'signed',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: SrThemeData.dark(),
        home: Scaffold(
          body: PermitPanel(state: state, request: request),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('details changed after you signed'),
      findsOneWidget,
    );
    expect(find.textContaining('Your e-signature is recorded'), findsNothing);
    expect(find.text('Sign e-signature'), findsNothing);
  });

  testWidgets('does not offer requester signature upload to an administrator', (
    tester,
  ) async {
    final state = AppState()
      ..sessionProfile = SessionProfile(
        id: 'admin-session-id',
        email: 'admin@csu.edu.ph',
        fullName: 'CSU Administrator',
        role: 'internal_admin',
        campusClaim: null,
        campusId: null,
        unit: null,
        verificationStatus: 'verified',
        onboardingComplete: true,
        accountStatus: 'active',
        accountAccessType: 'legacy_unassigned',
        mustChangePassword: false,
        createdAt: DateTime.utc(2026),
      );
    final request = ReservationRequest(
      id: 'reservation-id',
      requesterId: 'u1',
      facility: 'CSU Gymnasium',
      building: 'Main campus',
      room: 'Gymnasium',
      capacity: 100,
      requester: 'External requester',
      role: 'user',
      org: '',
      purpose: 'Event',
      date: '14 September 2026',
      start: '07:00',
      end: '14:00',
      heads: 10,
      submitted: 'Just now',
      urgent: false,
      attachments: 0,
      noShows: 0,
      status: RequestStatus.approved,
      lifecycleStatus: ReservationLifecycleStatus.confirmed,
      signatureRequestId: 'signature-request-id',
      signatureRequestStatus: 'requested',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: SrThemeData.dark(),
        home: Scaffold(
          body: PermitPanel(state: state, request: request),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Sign e-signature'), findsNothing);
    expect(
      find.textContaining('An e-signature request is active.'),
      findsOneWidget,
    );
    expect(find.text('Resend e-signature request'), findsOneWidget);
  });

  testWidgets(
    'does not present an official-generation failure as a requester action',
    (tester) async {
      final state = AppState()
        ..sessionProfile = SessionProfile(
          id: 'u1',
          email: 'requester@csu.edu.ph',
          fullName: 'Requester',
          role: 'user',
          campusClaim: null,
          campusId: null,
          unit: null,
          verificationStatus: 'verified',
          onboardingComplete: true,
          accountStatus: 'active',
          accountAccessType: 'legacy_unassigned',
          mustChangePassword: false,
          createdAt: DateTime.utc(2026),
        );
      final request = ReservationRequest(
        id: 'reservation-id',
        requesterId: 'u1',
        facility: 'CSU Gymnasium',
        building: 'Main campus',
        room: 'Gymnasium',
        capacity: 100,
        requester: 'Requester',
        role: 'user',
        org: '',
        purpose: 'Event',
        date: '14 September 2026',
        start: '07:00',
        end: '14:00',
        heads: 10,
        submitted: 'Just now',
        urgent: false,
        attachments: 0,
        noShows: 0,
        status: RequestStatus.approved,
        lifecycleStatus: ReservationLifecycleStatus.confirmed,
        signatureRequestId: 'signature-request-id',
        signatureRequestStatus: 'signed',
        permit: ReservationPermit.fromJson({
          'id': 'permit-id',
          'request_id': 'reservation-id',
          'permit_number': 'SR-2026-000001',
          'version': 1,
          'status': 'active',
          'issued_at': '2026-09-14T00:00:00Z',
          'template_kind': 'internal',
          'template_sha256': 'hash',
          'generation_status': 'failed',
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SrThemeData.dark(),
          home: Scaffold(
            body: PermitPanel(state: state, request: request),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('Your e-signature is recorded. The assigned'),
        findsOneWidget,
      );
      expect(
        find.textContaining('The permit could not be prepared'),
        findsNothing,
      );
      expect(find.text('Retry generation'), findsNothing);
    },
  );

  testWidgets(
    'lets the requester sign by drawing instead of uploading a file',
    (tester) async {
      final state = AppState()
        ..sessionProfile = SessionProfile(
          id: 'u1',
          email: 'requester@csu.edu.ph',
          fullName: 'Requester',
          role: 'user',
          campusClaim: null,
          campusId: null,
          unit: null,
          verificationStatus: 'verified',
          onboardingComplete: true,
          accountStatus: 'active',
          accountAccessType: 'legacy_unassigned',
          mustChangePassword: false,
          createdAt: DateTime.utc(2026),
        );
      final request = ReservationRequest(
        id: 'reservation-id',
        requesterId: 'u1',
        facility: 'CSU Gymnasium',
        building: 'Main campus',
        room: 'Gymnasium',
        capacity: 100,
        requester: 'Requester',
        role: 'user',
        org: '',
        purpose: 'Event',
        date: '14 September 2026',
        start: '07:00',
        end: '14:00',
        heads: 10,
        submitted: 'Just now',
        urgent: false,
        attachments: 0,
        noShows: 0,
        status: RequestStatus.approved,
        lifecycleStatus: ReservationLifecycleStatus.confirmed,
        signatureRequestId: 'signature-request-id',
        signatureRequestStatus: 'requested',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SrThemeData.dark(),
          home: Scaffold(
            body: PermitPanel(state: state, request: request),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Sign e-signature'), findsOneWidget);

      await tester.tap(find.text('Sign e-signature'));
      await tester.pumpAndSettle();

      expect(find.text('Sign your reservation permit'), findsOneWidget);
      SrButton confirmButton() => tester.widget<SrButton>(
        find.widgetWithText(SrButton, 'Confirm signature'),
      );
      expect(confirmButton().onPressed, isNull);

      final padSize = tester.getSize(find.byType(SignaturePad));
      await tester.dragFrom(
        tester.getTopLeft(find.byType(SignaturePad)) +
            Offset(padSize.width * 0.1, padSize.height * 0.1),
        Offset(padSize.width * 0.8, padSize.height * 0.6),
      );
      await tester.pump();

      expect(confirmButton().onPressed, isNotNull);
    },
  );
}
