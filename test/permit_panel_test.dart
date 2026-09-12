import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/model/permit.dart';

void main() {
  test('only a ready active permit with stored bytes is downloadable', () {
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
    expect(permit.isDownloadable, isTrue);
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
}
