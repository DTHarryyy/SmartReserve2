import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/model/reservation.dart';
import 'package:smartreserve/model/audit_entry.dart';
import 'package:smartreserve/widgets/side_nav.dart';
import 'package:smartreserve/app/app_view.dart';

void main() {
  test('audit entries parse server timestamps and structured changes', () {
    final entry = AuditEntry.fromJson({
      'id': 'entry-1',
      'actor_name': 'Registrar',
      'actor_role': 'internal_admin',
      'action': 'updated',
      'target_label': 'Computer Laboratory 1',
      'entity_type': 'facility',
      'entity_id': 'facility-1',
      'created_at': '2026-08-09T01:00:00Z',
      'material': true,
      'before_values': {'capacity': 30},
      'after_values': {'capacity': 40},
      'revertable': true,
    });
    expect(entry.recordId, 'facility-1');
    expect(entry.diff.single, 'capacity: 30 → 40');
    expect(entry.revertable, isTrue);
  });

  test('backend reservation maps occurrences, files, events, and payment', () {
    final row = BackendReservation.fromJson({
      'id': '10000000-0000-0000-0000-000000000001',
      'requester_id': '10000000-0000-0000-0000-000000000002',
      'facility_id': '10000000-0000-0000-0000-000000000003',
      'requester_name': 'Roel Dela Cruz',
      'requester_role': 'user',
      'requester_unit': 'BSIT',
      'facility_name': 'Computer Laboratory 1',
      'facility_building': 'ICT Building',
      'facility_room': 'ICT-201',
      'facility_capacity': 40,
      'purpose': 'Capstone presentation',
      'headcount': 30,
      'status': 'approved',
      'held_for_verification': false,
      'recurrence': 'weekly',
      'payment_amount_centavos': 50000,
      'payment_status': 'authorized',
      'version': 3,
      'created_at': '2026-08-08T01:00:00Z',
      'reservation_occurrences': [
        {
          'id': '20000000-0000-0000-0000-000000000001',
          'starts_at': '2026-08-10T01:00:00Z',
          'ends_at': '2026-08-10T03:00:00Z',
          'booking_state': 'booked',
          'lifecycle_stage': 'checked_in',
        },
      ],
      'reservation_attachments': [
        {
          'id': '30000000-0000-0000-0000-000000000001',
          'file_name': 'endorsement.pdf',
          'mime_type': 'application/pdf',
          'byte_size': 2048,
          'storage_path': 'user/request/file.pdf',
        },
      ],
      'reservation_events': [
        {
          'id': '40000000-0000-0000-0000-000000000001',
          'actor_name': 'Registrar',
          'actor_role': 'internal_admin',
          'action': 'approved',
          'created_at': '2026-08-08T02:00:00Z',
          'material': true,
          'details': {'source': 'test'},
        },
      ],
    });

    expect(row.occurrences, hasLength(1));
    expect(row.occurrences.single.lifecycleStage, 'checked_in');
    expect(row.attachments.single.fileName, 'endorsement.pdf');
    expect(row.events.single.action, 'approved');
    expect(row.paymentStatus, 'authorized');
    expect(row.version, 3);
  });

  test('database status names map to application states', () {
    expect(
      RequestStatus.fromRaw('changes_requested'),
      RequestStatus.changesRequested,
    );
    expect(
      PaymentTrackingStatus.fromRaw('captured'),
      PaymentTrackingStatus.captured,
    );
  });

  test('design notes are not an admin sidebar destination', () {
    expect(adminSections, isNot(contains(AppView.notes)));
    expect(
      AppView.values,
      contains(AppView.notes),
      reason: 'demo route remains',
    );
  });
}
