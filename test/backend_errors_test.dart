import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/util/backend_errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('reservation backend messages', () {
    test('hides a missing submit_reservation_v3 contract', () {
      const error = PostgrestException(
        message:
            'Could not find the function public.submit_reservation_v3 in the schema cache',
        code: 'PGRST202',
        details: 'Database signature details must not be displayed',
      );

      final message = reservationBackendMessage(error);

      expect(message, reservationServiceUpdatingMessage);
      expect(message, isNot(contains('submit_reservation_v3')));
      expect(message, isNot(contains('PGRST202')));
      expect(message, isNot(contains('schema cache')));
    });

    test('does not disguise ordinary reservation validation failures', () {
      const error = PostgrestException(
        message: 'Complete all external permit details',
        code: '22023',
      );

      expect(
        reservationBackendMessage(error),
        'Complete all external permit details.',
      );
    });

    test('keeps established conflict and concurrency messages', () {
      expect(
        reservationBackendMessage(
          const PostgrestException(message: 'slot booked', code: '23P01'),
        ),
        'That time was just booked. Refresh and choose another slot.',
      );
      expect(
        reservationBackendMessage(
          const PostgrestException(message: 'Pricing changed', code: '40001'),
        ),
        'This reservation changed in another session. It has been refreshed.',
      );
    });

    test('hides raw storage RLS failures from signature upload toasts', () {
      const error = StorageException(
        'new row violates row-level security policy',
        statusCode: '403',
        error: 'Unauthorized',
      );

      final message = reservationBackendMessage(error);

      expect(
        message,
        'Your signature upload was not authorized. Refresh the '
        'reservation and try again.',
      );
      expect(message.toLowerCase(), isNot(contains('row-level security')));
      expect(message, isNot(contains('403')));
      expect(message.toLowerCase(), isNot(contains('unauthorized')));
    });

    test('hides an unreachable permit function failure', () {
      final message = reservationBackendMessage(
        const FunctionException(
          status: 0,
          details: 'FunctionsFetchException(status: 0)',
        ),
      );

      expect(
        message,
        'The permit service could not be reached. Refresh and try again.',
      );
      expect(message, isNot(contains('FunctionsFetchException')));
      expect(message, isNot(contains('status: 0')));
    });
  });
}
