import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:smartreserve/data/campus_data.dart';
import 'package:smartreserve/data/seed_facilities.dart';
import 'package:smartreserve/model/facility_draft.dart';
import 'package:smartreserve/model/facility_photo.dart';
import 'package:smartreserve/util/geo.dart';

void main() {
  group('required items', () {
    test('a blank draft reports every requirement as outstanding', () {
      final draft = FacilityDraft();
      expect(draft.completeCount, 0);
      expect(draft.completePct, '0%');
      expect(draft.validate().keys, containsAll(RequiredItem.values));
    });

    test('a complete draft validates clean', () {
      final draft = FacilityDraft()
        ..name = 'Computer Laboratory 2'
        ..category = 'Computer Laboratory'
        ..capacity = '40'
        ..building = 'College of Information and Computing Sciences'
        ..pin = const LatLng(18.35378, 121.63142)
        ..accuracy = 4;
      draft.photos.add(FacilityPhoto.placeholder(0));

      expect(draft.validate(), isEmpty);
      expect(draft.completeCount, RequiredItem.values.length);
      expect(draft.completePct, '100%');
    });

    test('duplicate names are refused rather than silently created', () {
      final draft = FacilityDraft()..name = 'Computer Laboratory 1';
      expect(
        draft.validate(facilities: seedFacilities())[RequiredItem.name],
        contains('already exists'),
      );
    });

    test('capacity must be a positive whole number', () {
      expect(
        (FacilityDraft()..capacity = '0').validate()[RequiredItem.capacity],
        contains('at least 1'),
      );
      expect(
        (FacilityDraft()..capacity = '40').validate()[RequiredItem.capacity],
        isNull,
      );
    });
  });

  group('geo checks', () {
    test('the campus centre is inside the campus boundary', () {
      expect(inPolygon(campus.center, campus.boundary), isTrue);
    });

    test('a pin in the next barangay is outside the boundary', () {
      expect(
        inPolygon(const LatLng(18.3600, 121.6400), campus.boundary),
        isFalse,
      );
    });

    test('a 1 m nudge moves the pin about 1 m', () {
      const start = LatLng(18.35415, 121.63057);
      expect(haversine(start, nudge(start, north: 1)), closeTo(1, 0.01));
      expect(haversine(start, nudge(start, east: 1)), closeTo(1, 0.01));
    });

    test('pasted coordinates are accepted, prose is not', () {
      expect(parseCoords('18.3541, 121.6306'), isNotNull);
      expect(parseCoords('18.3541 121.6306'), isNotNull);
      expect(parseCoords('Administration Building'), isNull);
      expect(parseCoords('91.0, 121.6'), isNull, reason: 'latitude overflows');
    });

    test('accuracy tightens as the placement zoom increases', () {
      expect(accuracyForZoom(19), lessThan(accuracyForZoom(15)));
      expect(accuracyForZoom(21), greaterThanOrEqualTo(2));
    });

    test('reverse geocode names the building a close pin belongs to', () {
      final address = reverseGeocode(
        buildingNamed('Administration Building')!.coords,
      );
      expect(address.geoBuilding, 'Administration Building');
      expect(address.municipality, 'Aparri');
      expect(address.province, 'Cagayan');
    });

    test('a far-off pin is not attributed to any building', () {
      expect(reverseGeocode(const LatLng(18.40, 121.70)).geoBuilding, '');
    });

    test('compass wording matches the offset direction', () {
      const from = LatLng(18.35415, 121.63057);
      expect(compassFrom(from, nudge(from, north: 50)), 'north');
      expect(compassFrom(from, nudge(from, east: 50)), 'east');
    });
  });

  group('draft round-trip', () {
    test('a draft survives serialisation, pin included', () {
      final draft = FacilityDraft()
        ..name = 'Marine Annex'
        ..category = 'Science Laboratory'
        ..capacity = '24'
        ..building = 'College of Fisheries and Marine Sciences'
        ..pin = const LatLng(18.35298, 121.63052)
        ..accuracy = 6
        ..days = [true, false, true, false, true, false, false];
      draft.amenities.addAll(['Wi-Fi', 'Generator']);

      final restored = FacilityDraft.fromJson(draft.toJson());

      expect(restored.name, draft.name);
      expect(restored.pin, draft.pin);
      expect(restored.accuracy, 6);
      expect(restored.amenities, ['Wi-Fi', 'Generator']);
      expect(restored.days, draft.days);
      expect(restored.daysLine, 'Mon, Wed, Fri');
    });

    test('placeholder photos survive a round-trip, file photos may not', () {
      final draft = FacilityDraft()
        ..photos.addAll([
          FacilityPhoto.placeholder(1),
          const FacilityPhoto(id: 'gone', path: '/nowhere/missing.jpg'),
        ]);

      final restored = FacilityDraft.fromJson(draft.toJson());

      expect(restored.photos, hasLength(1));
      expect(restored.photos.single.isPlaceholder, isTrue);
    });

    test('a contiguous run of days is written as a range', () {
      expect(FacilityDraft().daysLine, 'Mon–Fri');
    });

    test('a blank draft is not dirty; one keystroke makes it dirty', () {
      expect(FacilityDraft().isDirty, isFalse);
      expect((FacilityDraft()..name = 'X').isDirty, isTrue);
    });
  });
}
