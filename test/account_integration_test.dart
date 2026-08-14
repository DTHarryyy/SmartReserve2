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
  role: 'user',
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
  test('authorization exposes exactly three fail-closed roles', () {
    expect(AccountRole.values, [
      AccountRole.user,
      AccountRole.internalAdmin,
      AccountRole.externalAdmin,
    ]);
    expect(() => AccountRole.fromRaw('student'), throwsArgumentError);
    expect(() => AccountRole.fromRaw('unexpected'), throwsArgumentError);
  });

  test('authenticated student account uses the Supabase profile', () async {
    final state = AppState();

    await state.applyBackendProfile(
      memberProfile(verificationStatus: 'verified'),
    );

    final account = state.userAccount;
    expect(account.id, '00000000-0000-0000-0000-000000000099');
    expect(account.name, 'Roel Dela Cruz');
    expect(account.email, 'roel@example.com');
    expect(account.role, AccountRole.user);
    expect(account.idNumber, '2026-00123');
    expect(account.unit, 'BS Information Technology');
    expect(account.verification, VerificationState.verified);
    expect(account.status, AccountStatus.active);
    expect(account.joined, '7 Aug 2026');
    expect(state.userDetailsEditable, isFalse);
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
        expect(state.userAccount.verification, entry.value);
        expect(state.userAccount.status, AccountStatus.suspended);
      }
    },
  );

  test('a sessionless state retains the seeded demo account fallback', () {
    final state = AppState()..signInAsUser('u3');

    expect(state.hasSession, isFalse);
    expect(state.userAccount.id, 'u3');
  });

  test('only verified users reserve free', () {
    final state = AppState()..signInAsUser('u3');

    expect(state.userAccount.verification, VerificationState.pending);
    expect(state.userAccount.reservesFree, isFalse);

    state.signInAsUser('u5');
    expect(state.userAccount.reservesFree, isFalse);
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

      expect(state.userAccount.suspendReason, 'Repeated no-shows');
      expect(state.userAccount.suspendUntil, '20 Aug 2026');
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
