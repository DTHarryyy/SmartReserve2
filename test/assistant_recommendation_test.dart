import 'package:flutter_test/flutter_test.dart';
import 'package:smartreserve/features/assistant/assistant_recommendation.dart';
import 'package:smartreserve/model/facility.dart';

Facility _facility({
  required String id,
  required String name,
  required int capacity,
  String category = 'Conference Room',
  List<String> amenities = const [],
  double? rating,
}) => Facility(
  id: id,
  name: name,
  room: '$id-01',
  building: 'Test Building',
  category: category,
  capacity: capacity,
  pinConfidence: PinConfidence.verified,
  state: FacilityState.active,
  floor: 'Ground floor',
  coords: null,
  accuracy: 5,
  description: '',
  amenities: amenities,
  hours: '07:00–19:00',
  days: 'Mon–Fri',
  approvalRequired: false,
  maxDuration: '4 hours',
  advance: '30 days ahead',
  updated: '',
  bookings: 0,
  ratingAverage: rating,
  ratingCount: rating == null ? 0 : 5,
);

void main() {
  group('capacity fit', () {
    test('the smallest adequate room outranks a much larger one', () {
      final ranked = rankFacilities(
        pool: [
          _facility(id: 'hall', name: 'Grand Hall', capacity: 900),
          _facility(id: 'aud', name: 'Auditorium', capacity: 220),
        ],
        criteria: const RecommendationCriteria(minCapacity: 200),
      );

      expect(ranked.first.facility.name, 'Auditorium');
      expect(ranked.first.reasons, contains(RecommendationReason.capacityFit));
      expect(ranked.last.reasons, contains(RecommendationReason.muchLarger));
    });

    test('rooms that cannot hold the party are dropped entirely', () {
      final ranked = rankFacilities(
        pool: [
          _facility(id: 'small', name: 'Small Room', capacity: 20),
          _facility(id: 'ok', name: 'Big Room', capacity: 250),
        ],
        criteria: const RecommendationCriteria(minCapacity: 200),
      );

      expect(ranked, hasLength(1));
      expect(ranked.single.facility.name, 'Big Room');
    });

    test('an exact fit scores above a merely adequate one', () {
      final ranked = rankFacilities(
        pool: [
          _facility(id: 'a', name: 'Exactly Right', capacity: 200),
          _facility(id: 'b', name: 'Roomy', capacity: 380),
        ],
        criteria: const RecommendationCriteria(minCapacity: 200),
      );

      expect(ranked.first.facility.name, 'Exactly Right');
      expect(ranked.first.score, greaterThan(ranked.last.score));
    });
  });

  group('amenities', () {
    test('a full match outranks a partial one', () {
      final ranked = rankFacilities(
        pool: [
          _facility(
            id: 'partial',
            name: 'Half Equipped',
            capacity: 30,
            amenities: ['Air Conditioning'],
          ),
          _facility(
            id: 'full',
            name: 'Fully Equipped',
            capacity: 30,
            amenities: ['Air Conditioning', 'Projector'],
          ),
        ],
        criteria: const RecommendationCriteria(
          amenities: {'Air Conditioning', 'Projector'},
        ),
      );

      expect(ranked.first.facility.name, 'Fully Equipped');
      expect(
        ranked.first.reasons,
        contains(RecommendationReason.hasAllAmenities),
      );
    });

    test('a near miss is still shown, with the gap named', () {
      // "Nothing matches" is a worse answer than "this one fits but has no
      // projector", so partial matches survive the ranking.
      final ranked = rankFacilities(
        pool: [
          _facility(
            id: 'partial',
            name: 'Half Equipped',
            capacity: 30,
            amenities: ['Air Conditioning'],
          ),
        ],
        criteria: const RecommendationCriteria(
          amenities: {'Air Conditioning', 'Projector'},
        ),
      );

      expect(ranked, hasLength(1));
      final only = ranked.single;
      expect(only.isPartialMatch, isTrue);
      expect(only.matchedAmenities, ['Air Conditioning']);
      expect(only.missingAmenities, ['Projector']);
      expect(only.reasons, contains(RecommendationReason.missingAmenity));
    });
  });

  group('category', () {
    test('"an office with aircon" prefers an office over a better-equipped room', () {
      final ranked = rankFacilities(
        pool: [
          _facility(
            id: 'conf',
            name: 'Conference Room',
            capacity: 20,
            category: 'Conference Room',
            amenities: ['Air Conditioning', 'Projector', 'Wi-Fi'],
          ),
          _facility(
            id: 'office',
            name: 'Registrar Office',
            capacity: 12,
            category: 'Office',
            amenities: ['Air Conditioning'],
          ),
        ],
        criteria: const RecommendationCriteria(
          category: 'Office',
          amenities: {'Air Conditioning'},
        ),
      );

      expect(ranked.first.facility.name, 'Registrar Office');
      expect(
        ranked.first.reasons,
        contains(RecommendationReason.categoryMatch),
      );
    });
  });

  group('availability', () {
    test('a facility free at the requested time is preferred', () {
      final ranked = rankFacilities(
        pool: [
          _facility(id: 'busy', name: 'Busy Room', capacity: 30),
          _facility(id: 'free', name: 'Free Room', capacity: 30),
        ],
        criteria: const RecommendationCriteria(),
        freeAtRequestedTime: (facility) => facility.id == 'free',
      );

      expect(ranked.first.facility.name, 'Free Room');
      expect(
        ranked.first.reasons,
        contains(RecommendationReason.freeAtRequestedTime),
      );
    });

    test('availability is ignored when no time was requested', () {
      final ranked = rankFacilities(
        pool: [
          _facility(id: 'a', name: 'Alpha', capacity: 30),
          _facility(id: 'b', name: 'Beta', capacity: 30),
        ],
        criteria: const RecommendationCriteria(),
      );

      expect(ranked.map((r) => r.score).toSet(), hasLength(1));
    });
  });

  test('rating only breaks ties, never beats a better fit', () {
    final ranked = rankFacilities(
      pool: [
        _facility(
          id: 'big',
          name: 'Beloved But Huge',
          capacity: 900,
          rating: 5,
        ),
        _facility(id: 'fit', name: 'Plain But Right', capacity: 210),
      ],
      criteria: const RecommendationCriteria(minCapacity: 200),
    );

    expect(ranked.first.facility.name, 'Plain But Right');
  });

  group('ordering and limits', () {
    test('results are capped so the answer stays short', () {
      final ranked = rankFacilities(
        pool: [
          for (var i = 0; i < 12; i++)
            _facility(id: 'f$i', name: 'Room $i', capacity: 30 + i),
        ],
        criteria: const RecommendationCriteria(),
      );

      expect(ranked, hasLength(5));
    });

    test('ties break by size then name, so ordering is reproducible', () {
      final first = rankFacilities(
        pool: [
          _facility(id: 'b', name: 'Bravo', capacity: 30),
          _facility(id: 'a', name: 'Alpha', capacity: 30),
        ],
        criteria: const RecommendationCriteria(),
      );
      final second = rankFacilities(
        pool: [
          _facility(id: 'a', name: 'Alpha', capacity: 30),
          _facility(id: 'b', name: 'Bravo', capacity: 30),
        ],
        criteria: const RecommendationCriteria(),
      );

      expect(
        first.map((r) => r.facility.name),
        second.map((r) => r.facility.name),
      );
      expect(first.first.facility.name, 'Alpha');
    });

    test('an empty pool yields nothing rather than throwing', () {
      expect(
        rankFacilities(
          pool: const [],
          criteria: const RecommendationCriteria(minCapacity: 10),
        ),
        isEmpty,
      );
    });
  });

  test('a free-text query filters by name, room, building or category', () {
    final ranked = rankFacilities(
      pool: [
        _facility(id: 'gym', name: 'Main Court', capacity: 900),
        _facility(id: 'lab', name: 'Computer Laboratory 1', capacity: 40),
      ],
      criteria: const RecommendationCriteria(query: 'court'),
    );

    expect(ranked.single.facility.name, 'Main Court');
  });

  test('every reason carries user-facing wording', () {
    for (final reason in RecommendationReason.values) {
      expect(reason.label, isNotEmpty);
    }
  });
}
