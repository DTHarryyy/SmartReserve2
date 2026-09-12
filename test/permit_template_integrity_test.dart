import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const expected = {
    'internal Permit.pdf':
        '4732b1b07c455531615faa3de2b6e2dd2631ec2e4fa609c34ff99e241f64cb58',
    'External Permit.pdf':
        'bf328cc2b7eadafae9be130e2ec93342c05dea78a3579f1fccbb58ce1d5767aa',
  };

  for (final entry in expected.entries) {
    test('${entry.key} canonical and deployment copies are byte-identical', () {
      final canonical = File('assets/permit/${entry.key}').readAsBytesSync();
      final deployed = File(
        'supabase/functions/generate-permit/templates/${entry.key}',
      ).readAsBytesSync();
      expect(sha256.convert(canonical).toString(), entry.value);
      expect(sha256.convert(deployed).toString(), entry.value);
      expect(deployed, canonical);
    });
  }
}
