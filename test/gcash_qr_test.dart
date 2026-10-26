import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/student/payment_proof_sheet.dart';
import 'package:smartreserve/model/payment.dart';
import 'package:smartreserve/model/reservation.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/util/campus_calendar.dart';

class _QrBackend implements SmartReserveBackend {
  @override
  String paymentQrUrl(String path) => 'https://storage.example.test/$path';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected call: ${invocation.memberName}');
}

ReservationRequest _request(FacilityPaymentMethod method) {
  final start = campusNow().add(const Duration(days: 7));
  return ReservationRequest(
    id: 'req-qr',
    facility: 'QR Hall',
    building: 'Test Building',
    room: 'T-01',
    capacity: 40,
    requester: 'Renter',
    role: 'Guest',
    org: 'Outside renter',
    purpose: 'QR fixture',
    date: formatCampusDate(start),
    start: '08:00',
    end: '10:00',
    heads: 10,
    submitted: 'today',
    urgent: false,
    attachments: 0,
    noShows: 0,
    status: RequestStatus.approved,
    lifecycleStatus: ReservationLifecycleStatus.awaitingPayment,
    totalAmountCentavos: 100000,
    requiredDownPaymentCentavos: 50000,
    paymentDueAt: campusNow().add(const Duration(days: 1)),
    balanceDueAt: start.subtract(const Duration(days: 1)),
    paymentMethod: method,
    occurrences: [
      ReservationOccurrence(
        id: 'occ-qr',
        startsAt: start,
        endsAt: start.add(const Duration(hours: 2)),
        bookingState: 'booked',
      ),
    ],
  );
}

Future<void> _openSheet(
  WidgetTester tester,
  AppState state,
  ReservationRequest request,
) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: MaterialApp(
        theme: SrThemeData.light(),
        builder: (context, child) =>
            SrThemeBridge(child: child ?? const SizedBox.shrink()),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPaymentProofSheet(
                context,
                state: state,
                request: request,
              ),
              child: const Text('Pay'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Pay'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  const gcash = FacilityPaymentMethod(
    id: 'pm-1',
    facilityId: 'fac-1',
    accountName: 'Janna Grace Somera',
    accountNumber: '09123456789',
    instructions: 'Pay by GCash.',
    qrPath: 'fac-1/gcash.png',
  );

  test('only GCash destinations with a path carry a QR', () {
    expect(gcash.hasQr, isTrue);
    expect(
      const FacilityPaymentMethod(
        id: 'pm-2',
        facilityId: 'fac-1',
        accountName: 'Cashier',
        accountNumber: '0000000000',
        instructions: '',
        methodType: 'walk_in',
        qrPath: 'fac-1/x.png',
      ).hasQr,
      isFalse,
    );
    expect(
      const FacilityPaymentMethod(
        id: 'pm-3',
        facilityId: 'fac-1',
        accountName: 'A',
        accountNumber: '09123456789',
        instructions: '',
      ).hasQr,
      isFalse,
    );
  });

  testWidgets('the payment dialog shows the uploaded GCash QR', (tester) async {
    final state = AppState(useDemoData: false)..backend = _QrBackend();

    await _openSheet(tester, state, _request(gcash));

    expect(find.byKey(const Key('payment-gcash-qr')), findsOneWidget);
    final image = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const Key('payment-gcash-qr')),
        matching: find.byType(Image),
      ),
    );
    expect(
      (image.image as NetworkImage).url,
      'https://storage.example.test/fac-1/gcash.png',
    );
    expect(find.text('Open QR full size'), findsOneWidget);
  });

  testWidgets('no QR is shown for a number-only destination', (tester) async {
    final state = AppState(useDemoData: false)..backend = _QrBackend();
    const numberOnly = FacilityPaymentMethod(
      id: 'pm-1',
      facilityId: 'fac-1',
      accountName: 'Janna Grace Somera',
      accountNumber: '09123456789',
      instructions: 'Pay by GCash.',
    );

    await _openSheet(tester, state, _request(numberOnly));

    expect(find.text('Submit payment proof'), findsOneWidget);
    expect(find.byKey(const Key('payment-gcash-qr')), findsNothing);
  });
}
