import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/audit_diff.dart';
import 'package:smartreserve/util/campus_calendar.dart';

void main() {
  group('humanizeAuditPayload', () {
    test('an account invite summarises to a few plain-language lines', () {
      const invitationSentAt = '2026-08-08T09:08:04.166+00:00';
      final changes = humanizeAuditPayload(
        entityType: 'account',
        action: 'invite',
        before: const {},
        after: const {
          'id': '48b71f44-4f53-4d26-9aa3-126fec41562c',
          'role': 'external_admin',
          'email': 'hdetorres1134@gmail.com',
          'full_name': '',
          'created_at': '2026-08-08T09:07:58.642566+00:00',
          'account_status': 'invited',
          'invitation_sent_at': invitationSentAt,
          'verification_status': 'none',
        },
      );

      final rendered = changes
          .map(
            (c) =>
                '${c.label}:${c.before ?? ''}${c.after ?? ''}${c.note ?? ''}',
          )
          .join('\n');

      expect(rendered, isNot(contains('48b71f44-4f53-4d26-9aa3-126fec41562c')));
      expect(rendered, isNot(contains('T09:')));
      expect(rendered, isNot(contains('+00:00')));

      expect(changes.length, 3);
      expect(changes[0].label, 'Role');
      expect(changes[0].after, 'External admin');
      expect(changes[1].label, 'Status');
      expect(changes[1].after, 'Invited');
      expect(changes[2].label, 'Invitation sent');
      final expectedStamp = formatStamp(
        DateTime.parse(invitationSentAt).toLocal(),
      );
      expect(changes[2].after, expectedStamp);
      expect(changes.any((c) => c.label == 'Name'), isFalse);
    });

    test('facility latitude/longitude collapse into one Location change', () {
      final changes = humanizeAuditPayload(
        entityType: 'facility',
        action: 'updated',
        before: const {
          'latitude': 18.353720,
          'longitude': 121.631380,
          'capacity': 60,
        },
        after: const {
          'latitude': 18.353780,
          'longitude': 121.631420,
          'capacity': 60,
        },
      );

      final location = changes.singleWhere((c) => c.label == 'Location');
      expect(location.before, '18.353720, 121.631380');
      expect(location.after, '18.353780, 121.631420');
      expect(changes.any((c) => c.label == 'Capacity'), isFalse);
    });

    test('a change with no surviving fields falls back to a note', () {
      final changes = humanizeAuditPayload(
        entityType: 'reservation',
        action: 'resend_invite',
        before: const {'id': 'a', 'updated_at': 'x'},
        after: const {'id': 'a', 'updated_at': 'y'},
      );

      expect(changes, hasLength(1));
      expect(changes.single.isNote, isTrue);
      expect(changes.single.note, contains('no field changes recorded'));
    });
  });
}
