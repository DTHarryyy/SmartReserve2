import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/app/app_view.dart';
import 'package:smartreserve/backend/supabase_service.dart';

SessionProfile profile({
  required String role,
  required bool onboardingComplete,
}) => SessionProfile(
  id: '00000000-0000-0000-0000-000000000001',
  email: 'member@example.com',
  fullName: 'Smart Reserve Member',
  role: role,
  campusClaim: null,
  campusId: null,
  unit: null,
  verificationStatus: 'none',
  onboardingComplete: onboardingComplete,
  accountStatus: 'active',
  createdAt: DateTime.utc(2026, 8, 7),
);

void main() {
  test('an app without a session starts at sign in', () {
    expect(AppState().view, AppView.auth);
  });

  test('an internal admin session starts at the admin dashboard', () async {
    final state = AppState();

    await state.applyBackendProfile(
      profile(role: 'internal_admin', onboardingComplete: true),
    );

    expect(state.view, AppView.facilities);
  });

  test('an external admin session starts at the admin dashboard', () async {
    final state = AppState();

    await state.applyBackendProfile(
      profile(role: 'external_admin', onboardingComplete: true),
    );

    expect(state.view, AppView.facilities);
  });

  test('a completed member session starts at the member dashboard', () async {
    final state = AppState();

    await state.applyBackendProfile(
      profile(role: 'student', onboardingComplete: true),
    );

    expect(state.view, AppView.studentApp);
  });
}
