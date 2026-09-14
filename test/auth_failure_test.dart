import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/auth/auth_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('auth failure classification', () {
    test(
      'classifies invalid credentials without exposing the backend message',
      () {
        final failure = classifyAuthFailure(
          const AuthException('Invalid login credentials', statusCode: '400'),
        );

        expect(failure.kind, AuthFailureKind.invalidCredentials);
        expect(
          AuthController.userMessageFor(failure),
          'That email address or password is incorrect.',
        );
      },
    );

    test('shows an actionable message when the new password is reused', () {
      final failure = classifyAuthFailure(
        const AuthException(
          'New password should be different from the old password.',
          statusCode: '422',
          code: 'same_password',
        ),
      );

      expect(failure.kind, AuthFailureKind.samePassword);
      expect(
        AuthController.userMessageFor(failure),
        'Your new password must be different from your current password.',
      );

      final edgeFailure = classifyAuthFailure(
        const AccountManagementException(
          code: 'same_password',
          message: 'backend detail must not be displayed',
          status: 422,
        ),
      );
      expect(edgeFailure.kind, AuthFailureKind.samePassword);
      expect(
        AuthController.userMessageFor(edgeFailure),
        'Your new password must be different from your current password.',
      );
    });

    test('maps password reset expiry and reauthentication failures', () {
      final expired = classifyAuthFailure(
        const AuthException(
          'Token expired',
          statusCode: '403',
          code: 'otp_expired',
        ),
      );
      final reauthenticate = classifyAuthFailure(
        const AuthException(
          'Reauthentication required',
          statusCode: '403',
          code: 'reauthentication_needed',
        ),
      );

      expect(expired.kind, AuthFailureKind.recoveryCodeExpired);
      expect(
        AuthController.userMessageFor(expired),
        'That password-reset code has expired. Request a new code.',
      );
      expect(
        reauthenticate.kind,
        AuthFailureKind.passwordReauthenticationRequired,
      );
    });

    test('classifies missing session RPC as a deployment issue', () {
      final failure = classifyAuthFailure(
        const PostgrestException(
          message: 'Function public.get_my_session_profile was not found',
          code: 'PGRST202',
        ),
      );

      expect(failure.kind, AuthFailureKind.profileContractUnavailable);
      expect(
        AuthController.userMessageFor(failure),
        'SmartReserve is updating account access. Please try again shortly.',
      );
    });

    test('classifies missing legacy profile schema as a deployment issue', () {
      for (final error in const [
        PostgrestException(
          message: 'The relationship could not be found in the schema cache',
          code: 'PGRST200',
        ),
        PostgrestException(
          message: 'Could not find the table in the schema cache',
          code: 'PGRST205',
        ),
        PostgrestException(message: 'relation does not exist', code: '42P01'),
      ]) {
        final failure = classifyAuthFailure(error);

        expect(failure.kind, AuthFailureKind.profileContractUnavailable);
        expect(
          AuthController.userMessageFor(failure),
          'SmartReserve is updating account access. Please try again shortly.',
        );
      }
    });

    test('maps profile and policy failures to safe fixed messages', () {
      expect(
        AuthController.userMessageFor(
          const AuthSessionException(kind: AuthFailureKind.profileMissing),
        ),
        'Your credentials were accepted, but this account has not been set up. Contact an Internal Admin.',
      );
      expect(
        AuthController.userMessageFor(
          const AuthSessionException(kind: AuthFailureKind.profileAccessDenied),
        ),
        'This account cannot load its access profile. Contact an Internal Admin.',
      );
    });

    test('does not show raw backend details for unknown failures', () {
      const raw = 'PostgrestException(message: private database detail)';
      final message = AuthController.userMessageFor(
        const AuthSessionException(kind: AuthFailureKind.unknown),
      );

      expect(message, 'We couldn’t complete sign-in. Please try again.');
      expect(message, isNot(contains(raw)));
      expect(message, isNot(contains('database')));
    });
  });
}
