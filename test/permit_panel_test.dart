import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/permit.dart';

void main() {
  test('only a sent ready active permit with stored bytes is downloadable', () {
    final permit = ReservationPermit.fromJson({
      'id': 'permit',
      'request_id': 'request',
      'permit_number': 'SR-2026-000001',
      'version': 1,
      'status': 'active',
      'issued_at': '2026-09-12T00:00:00Z',
      'template_kind': 'internal',
      'template_sha256': 'hash',
      'generation_status': 'ready',
      'storage_path': 'user/request/permit.pdf',
    });
    expect(permit.templateKind, PermitTemplateKind.internal);
    expect(permit.isGenerated, isTrue);
    expect(permit.isDownloadable, isFalse);

    final delivered = ReservationPermit.fromJson({
      'id': 'permit',
      'request_id': 'request',
      'permit_number': 'SR-2026-000001',
      'version': 1,
      'status': 'active',
      'issued_at': '2026-09-12T00:00:00Z',
      'template_kind': 'internal',
      'template_sha256': 'hash',
      'generation_status': 'ready',
      'storage_path': 'user/request/permit.pdf',
      'delivery_status': 'sent',
      'delivered_at': '2026-09-12T01:00:00Z',
    });
    expect(delivered.isDelivered, isTrue);
    expect(delivered.isDownloadable, isTrue);
  });

  test('readiness exposes precise user-facing blocker messages', () {
    final readiness = PermitReadiness.fromJson({
      'ready': false,
      'template_kind': 'external',
      'blockers': ['full_payment_required', 'external_details_required'],
    });
    expect(readiness.ready, isFalse);
    expect(
      readiness.messageFor(readiness.blockerCodes.first),
      contains('Full payment'),
    );
  });

  test('readiness parses the authoritative requester signature state', () {
    final stale = PermitReadiness.fromJson({
      'ready': false,
      'template_kind': 'internal',
      'blockers': ['requester_signature_required'],
      'requester_signature_state': 'stale',
    });
    final compatibleCurrent = PermitReadiness.fromJson({
      'ready': true,
      'template_kind': 'internal',
      'blockers': <String>[],
    });

    expect(stale.requesterSignatureState, PermitRequesterSignatureState.stale);
    expect(
      compatibleCurrent.requesterSignatureState,
      PermitRequesterSignatureState.current,
    );
    for (final entry in {
      'current': PermitRequesterSignatureState.current,
      'requested': PermitRequesterSignatureState.requested,
      'stale': PermitRequesterSignatureState.stale,
      'missing': PermitRequesterSignatureState.missing,
    }.entries) {
      final parsed = PermitReadiness.fromJson({
        'ready': entry.key == 'current',
        'template_kind': 'internal',
        'blockers': entry.key == 'current'
            ? <String>[]
            : ['requester_signature_required'],
        'requester_signature_state': entry.key,
      });
      expect(parsed.requesterSignatureState, entry.value);
    }
  });

  test('readiness retains real mapping requirements from the server', () {
    final readiness = PermitReadiness.fromJson({
      'ready': false,
      'template_kind': 'internal',
      'blockers': ['unmapped_permit_item'],
      'configuration': {
        'ready': false,
        'missing_mappings': [
          {
            'source_kind': 'facility',
            'source_id': 'facility-id',
            'label': 'Basketball Court',
            'lane': 'internal',
            'can_configure': true,
          },
        ],
      },
    });
    expect(readiness.configurationReady, isFalse);
    expect(readiness.missingMappings.single.isFacility, isTrue);
    expect(readiness.missingMappings.single.label, 'Basketball Court');
  });
}
