import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/account.dart';

void main() {
  group('account terminology', () {
    test('maps stored account values without changing backend contracts', () {
      expect(AccountRole.user.label, 'Internal user');
      expect(AccountAccessType.externalGuest.label, 'External renter');
      expect(VerificationState.none.label, 'Not verified');
      expect(bookingAudienceLabel('guest'), 'Renter');
      expect(bookingRateLabel('guest'), 'Renter rate');
    });

    test('uses renter only for external reservation roles', () {
      for (final value in ['guest', 'renter', 'external renter']) {
        expect(requesterRoleLabel(value), 'Renter');
      }
      for (final value in ['user', 'student', 'faculty', 'staff']) {
        expect(requesterRoleLabel(value), 'Internal user');
      }
      expect(requesterRoleLabel('User · BSIT 4A'), 'Internal user · BSIT 4A');
      expect(
        requesterRoleLabel('Renter · Outside organization'),
        'Renter · Outside organization',
      );
      expect(requesterRoleLabel('internal_admin'), 'Internal admin');
      expect(requesterRoleLabel('external_admin'), 'External admin');
    });

    test('reserves guest for people without an account', () {
      expect(userTypeLabel(hasAccount: false), 'Guest');
      expect(userTypeLabel(hasAccount: true, role: 'user'), 'Internal user');
      expect(userTypeLabel(hasAccount: true, role: 'guest'), 'Renter');
      expect(
        userTypeLabel(hasAccount: true, role: 'user', external: true),
        'Renter',
      );
    });

    test('account display role follows its access type', () {
      expect(_account(AccountAccessType.externalGuest).roleLabel, 'Renter');
      expect(
        _account(AccountAccessType.organizationRepresentative).roleLabel,
        'Internal user',
      );
      expect(
        _account(AccountAccessType.legacyUnassigned).roleLabel,
        'Internal user',
      );
    });

    test('normalizes generated copy only at the registered-user display', () {
      expect(
        registeredUserDisplayText('Guests pay the guest rate. GUEST ACCESS'),
        'Renters pay the renter rate. RENTER ACCESS',
      );
    });
  });
}

Account _account(AccountAccessType accessType) => Account(
  id: accessType.raw,
  name: 'Test User',
  email: 'test@example.com',
  role: AccountRole.user,
  unit: 'Test unit',
  idNumber: 'TEST-1',
  verification: VerificationState.verified,
  status: AccountStatus.active,
  reservations: 0,
  lastActive: 'Now',
  joined: 'Today',
  noShows: 0,
  accountAccessType: accessType,
);
