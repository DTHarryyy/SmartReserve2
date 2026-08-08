import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/app/app_state.dart';
import 'package:smartreserve/backend/supabase_service.dart';
import 'package:smartreserve/data/seed_facilities.dart';
import 'package:smartreserve/model/facility_draft.dart';

void main() {
  test('production state starts without demo facilities', () {
    final state = AppState(useDemoData: false);

    expect(state.facilities, isEmpty);
    expect(state.catalogueTotal, 0);
    expect(state.mappedCount, 0);
  });

  test('backend facility maps database fields and ordered remote photos', () {
    final backend = BackendFacility.fromJson({
      'id': '10000000-0000-0000-0000-000000000100',
      'name': 'Digital Learning Room',
      'room': 'DLR-1',
      'building': 'Administration Building',
      'category': 'Classroom',
      'capacity': 32,
      'status': 'active',
      'pin_confidence': 'verified',
      'campus_name': 'CSU Aparri Campus',
      'floor': 'Ground floor',
      'latitude': 18.35492,
      'longitude': 121.62931,
      'accuracy': 4,
      'confirmed_outside': false,
      'description': 'A connected classroom.',
      'geo_building': 'Administration Building',
      'street': 'University Avenue',
      'barangay': 'Macanaya',
      'municipality': 'Aparri',
      'province': 'Cagayan',
      'region': 'Region II',
      'country': 'Philippines',
      'geo_edited': <String>[],
      'amenities': ['Wi-Fi', 'Projector'],
      'photo_paths': ['admin/cover.jpg', 'admin/second.png'],
      'requires_approval': true,
      'public_listing': true,
      'open_days': [true, true, true, true, true, false, false],
      'open_time': '07:00:00',
      'close_time': '19:00:00',
      'max_duration': '4 hours',
      'advance_booking': '30 days ahead',
      'booking_buffer': '15 minutes',
      'booking_count': 0,
      'updated_by_name': 'Registrar',
      'updated_at': '2026-08-07T12:00:00Z',
    });

    final facility = backend.toFacility(
      (path) => 'https://example.test/storage/$path',
    );

    expect(facility.name, 'Digital Learning Room');
    expect(facility.coords?.latitude, 18.35492);
    expect(facility.days, 'Mon–Fri');
    expect(facility.photos, hasLength(2));
    expect(facility.coverPhoto?.storagePath, 'admin/cover.jpg');
    expect(
      facility.coverPhoto?.publicUrl,
      'https://example.test/storage/admin/cover.jpg',
    );
  });

  test('duplicate validation uses live facilities and ignores edited row', () {
    final existing = seedFacilities().first;
    final draft = FacilityDraft()..name = existing.name;

    expect(
      draft.validate(facilities: [existing])[RequiredItem.name],
      contains('already exists'),
    );
    expect(
      draft.validate(
        facilities: [existing],
        editingId: existing.id,
      )[RequiredItem.name],
      isNull,
    );
  });
}
