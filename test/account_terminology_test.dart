import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/account.dart';

void main() {
  group('registered renter terminology', () {
    test('maps stored account values without changing backend contracts', () {
      expect(AccountRole.user.label, 'Renter');
      expect(AccountAccessType.externalGuest.label, 'External renter');
      expect(VerificationState.none.label, 'Not verified');
      expect(bookingAudienceLabel('guest'), 'Renter');
      expect(bookingRateLabel('guest'), 'Renter rate');
    });

    test('maps current and legacy reservation roles to renter', () {
      for (final value in ['user', 'guest', 'student', 'faculty', 'staff']) {
        expect(requesterRoleLabel(value), 'Renter');
      }
      expect(requesterRoleLabel('User · BSIT 4A'), 'Renter · BSIT 4A');
      expect(requesterRoleLabel('internal_admin'), 'Internal admin');
      expect(requesterRoleLabel('external_admin'), 'External admin');
    });

    test('reserves guest for people without an account', () {
      expect(userTypeLabel(hasAccount: false), 'Guest');
      expect(userTypeLabel(hasAccount: true, role: 'user'), 'Renter');
      expect(userTypeLabel(hasAccount: true, role: 'guest'), 'Renter');
    });

    test('normalizes generated copy only at the registered-user display', () {
      expect(
        registeredUserDisplayText('Guests pay the guest rate. GUEST ACCESS'),
        'Renters pay the renter rate. RENTER ACCESS',
      );
    });
  });
}
