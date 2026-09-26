import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_scope.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/features/student/student_app.dart';
import 'package:smartreserve/model/reservation.dart';
import 'package:smartreserve/theme/sr_theme.dart';
import 'package:smartreserve/widgets/evidence_thumbnails.dart';

Future<void> _pumpMyReservations(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(1024, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    AppScope(
      state: state,
      child: MaterialApp(
        theme: SrThemeData.light(),
        debugShowCheckedModeBanner: false,
        builder: (context, child) =>
            SrThemeBridge(child: child ?? const SizedBox.shrink()),
        home: const Scaffold(body: StudentApp()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Reservation').last);
  await tester.pumpAndSettle();
}

ReservationUseAssessmentFile _file(int n) => ReservationUseAssessmentFile(
  id: 'file-$n',
  assessmentId: 'assessment-1',
  storagePath: 'req-1/occ-1/photo-$n.jpg',
  fileName: 'photo-$n.jpg',
  mimeType: 'image/jpeg',
  byteSize: 1024,
);

ReservationRequest _assessedRequest(List<ReservationUseAssessmentFile> files) =>
    ReservationRequest(
      id: 'assessed-r1',
      facility: 'Computer Laboratory 1',
      building: 'College of Information and Computing Sciences',
      room: 'CICS-201',
      capacity: 40,
      requester: 'Jomar Padilla',
      role: 'User · BSIT 4A',
      org: 'Junior Philippine Computer Society',
      purpose: 'A completed booking an administrator has assessed.',
      date: 'Tue 28 Jul',
      start: '09:00',
      end: '11:00',
      heads: 32,
      submitted: '3 days ago',
      urgent: false,
      attachments: 0,
      noShows: 0,
      status: RequestStatus.approved,
      lifecycleStatus: ReservationLifecycleStatus.completed,
      useAssessments: [
        ReservationUseAssessment(
          id: 'assessment-1',
          requestId: 'assessed-r1',
          occurrenceId: 'occ-1',
          facilityId: 'fac-1',
          requesterId: 'user-1',
          adminId: 'admin-1',
          cleanlinessRating: 2,
          equipmentConditionRating: 4,
          leftUnclean: true,
          equipmentDamaged: false,
          comment: 'Trash was left under the desks.',
          revision: 1,
          createdAt: DateTime(2026, 9, 2),
          updatedAt: DateTime(2026, 9, 2),
          files: files,
        ),
      ],
    );

void main() {
  test('assessment JSON carries its embedded evidence files', () {
    final assessment = BackendReservationUseAssessment.fromJson({
      'id': 'assessment-1',
      'request_id': 'req-1',
      'occurrence_id': 'occ-1',
      'facility_id': 'fac-1',
      'requester_id': 'user-1',
      'admin_id': 'admin-1',
      'cleanliness_rating': 2,
      'equipment_condition_rating': 4,
      'left_unclean': true,
      'comment': 'Trash was left under the desks.',
      'created_at': '2026-09-02T00:00:00Z',
      'updated_at': '2026-09-02T00:00:00Z',
      'reservation_use_assessment_files': [
        {
          'id': 'file-1',
          'assessment_id': 'assessment-1',
          'storage_path': 'req-1/occ-1/photo-1.jpg',
          'file_name': 'photo-1.jpg',
          'mime_type': 'image/jpeg',
          'byte_size': 2048,
        },
      ],
    });

    expect(assessment.files, hasLength(1));
    expect(assessment.files.single.storagePath, 'req-1/occ-1/photo-1.jpg');
  });

  group('renter view of admin facility-use feedback', () {
    testWidgets('shows one thumbnail per evidence photo', (tester) async {
      final state = AppState();
      state.requests = [
        _assessedRequest([_file(1), _file(2)]),
        ...state.requests,
      ];

      await _pumpMyReservations(tester, state);

      expect(find.text('Admin facility-use feedback'), findsOneWidget);
      expect(find.text('Trash was left under the desks.'), findsOneWidget);
      expect(find.byType(EvidenceThumbnailStrip), findsOneWidget);
      expect(find.bySemanticsLabel('Evidence photo 1 of 2'), findsOneWidget);
      expect(find.bySemanticsLabel('Evidence photo 2 of 2'), findsOneWidget);
    });

    testWidgets('renders no strip when the admin attached no photos', (
      tester,
    ) async {
      final state = AppState();
      state.requests = [_assessedRequest(const []), ...state.requests];

      await _pumpMyReservations(tester, state);

      expect(find.text('Admin facility-use feedback'), findsOneWidget);
      expect(find.byType(EvidenceThumbnailStrip), findsNothing);
    });
  });
}
