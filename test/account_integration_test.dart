import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/auth/auth_controller.dart';
import 'package:smartreserve/model/account.dart';
import 'package:smartreserve/model/verification.dart';

SessionProfile memberProfile({
  String verificationStatus = 'none',
  String accountStatus = 'active',
  String? suspensionReason,
  DateTime? suspendedUntil,
}) => SessionProfile(
  id: '00000000-0000-0000-0000-000000000099',
  email: 'roel@example.com',
  fullName: 'Roel Dela Cruz',
  role: 'student',
  campusClaim: 'student',
  campusId: '2026-00123',
  unit: 'BS Information Technology',
  verificationStatus: verificationStatus,
  onboardingComplete: true,
  accountStatus: accountStatus,
  createdAt: DateTime.utc(2026, 8, 7, 12),
  suspensionReason: suspensionReason,
  suspendedUntil: suspendedUntil,
);

void main() {
  test('authenticated student account uses the Supabase profile', () async {
    final state = AppState();

    await state.applyBackendProfile(
      memberProfile(verificationStatus: 'verified'),
    );

    final account = state.studentAccount;
    expect(account.id, '00000000-0000-0000-0000-000000000099');
    expect(account.name, 'Roel Dela Cruz');
    expect(account.email, 'roel@example.com');
    expect(account.role, AccountRole.student);
    expect(account.idNumber, '2026-00123');
    expect(account.unit, 'BS Information Technology');
    expect(account.verification, VerificationState.verified);
    expect(account.status, AccountStatus.active);
    expect(account.joined, '7 Aug 2026');
    expect(state.studentDetailsEditable, isFalse);
  });

  test(
    'profile verification and account states are mapped accurately',
    () async {
      final cases = <String, VerificationState>{
        'none': VerificationState.none,
        'pending': VerificationState.pending,
        'verified': VerificationState.verified,
        'rejected': VerificationState.rejected,
      };

      for (final entry in cases.entries) {
        final state = AppState();
        await state.applyBackendProfile(
          memberProfile(
            verificationStatus: entry.key,
            accountStatus: 'suspended',
          ),
        );
        expect(state.studentAccount.verification, entry.value);
        expect(state.studentAccount.status, AccountStatus.suspended);
      }
    },
  );

  test('a sessionless state retains the seeded demo account fallback', () {
    final state = AppState()..signInAsStudent('u3');

    expect(state.hasSession, isFalse);
    expect(state.studentAccount.id, 'u3');
  });

  test('pending campus users can reserve without a guest-rate quote', () {
    final state = AppState()..signInAsStudent('u3');

    expect(state.studentAccount.verification, VerificationState.pending);
    expect(state.studentAccount.reservesFree, isTrue);

    state.signInAsStudent('u5');
    expect(state.studentAccount.reservesFree, isFalse);
  });

  test(
    'a persisted suspension blocks new requests and keeps its reason',
    () async {
      final state = AppState();
      await state.applyBackendProfile(
        memberProfile(
          verificationStatus: 'verified',
          accountStatus: 'suspended',
          suspensionReason: 'Repeated no-shows',
          suspendedUntil: DateTime(2026, 8, 20),
        ),
      );

      expect(state.studentAccount.suspendReason, 'Repeated no-shows');
      expect(state.studentAccount.suspendUntil, '20 Aug 2026');
      expect(
        () => state.submitBooking(
          facility: state.facilities.first,
          date: '11 Aug 2026',
          start: '09:00',
          end: '10:00',
          heads: 10,
          purpose: 'Class meeting',
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('restored verification sessions recover the current submission', () {
    final state = AppState();
    state.sessionProfile = memberProfile(verificationStatus: 'pending');
    state.myVerification = BackendVerification(
      id: 'verification-1',
      userId: state.sessionProfile!.id,
      name: state.sessionProfile!.fullName,
      email: state.sessionProfile!.email,
      claimType: 'student',
      campusId: '2026-00123',
      unit: 'BS Information Technology',
      documentName: 'registration.pdf',
      documentPath: '${state.sessionProfile!.id}/current',
      status: 'pending',
      reason: null,
      submittedAt: DateTime.utc(2026, 8, 7, 12),
      decidedAt: null,
    );
    state.verifications = [
      VerificationSubmission(
        id: 'verification-1',
        name: 'Roel Dela Cruz',
        email: 'roel@example.com',
        kind: 'Student',
        idNumber: '2026-00123',
        unit: 'BS Information Technology',
        document: 'registration.pdf',
        submitted: '7 Aug 2026',
        registryMatch: true,
        nameMatch: true,
        alreadyClaimed: false,
        legible: true,
        decision: VerificationDecision.pending,
      ),
    ];

    final controller = AuthController(state);
    addTearDown(controller.dispose);

    expect(controller.step, AuthStep.pending);
    expect(controller.submission?.id, 'verification-1');
  });
}
