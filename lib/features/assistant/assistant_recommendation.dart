/// Rule-based facility recommendation.
///
/// "Suggest a facility for 200 people" and "recommend an office with aircon"
/// must never become a model opinion: the ordering here is deterministic and
/// fully testable, and the AI layer only ever phrases a list this module has
/// already ranked. Every score component is documented so a reason code can be
/// attached to each result and the spoken explanation can never diverge from
/// the ordering that produced it.
library;

import '../../model/facility.dart';

/// Why a facility earned its place, in the order they are worth saying aloud.
enum RecommendationReason {
  /// Every requested amenity is present.
  hasAllAmenities,

  /// At least one requested amenity is missing -- the row is still shown, with
  /// the gap named, because "nothing matches" is a worse answer than "this one
  /// fits but has no projector".
  missingAmenity,

  /// Capacity comfortably fits the party without being wastefully oversized.
  capacityFit,

  /// Much larger than asked for. Kept, but ranked below a closer fit.
  muchLarger,

  /// Matches the requested category.
  categoryMatch,

  /// Free for the requested window.
  freeAtRequestedTime,

  /// Highest rated among the candidates.
  highestRated,
}

extension RecommendationReasonLabel on RecommendationReason {
  /// Short user-facing fragment. Deliberately lowercase and clause-shaped so
  /// callers can join several into one sentence.
  String get label => switch (this) {
    RecommendationReason.hasAllAmenities => 'has everything you asked for',
    RecommendationReason.missingAmenity => 'missing some of what you asked for',
    RecommendationReason.capacityFit => 'the right size',
    RecommendationReason.muchLarger => 'larger than you need',
    RecommendationReason.categoryMatch => 'the category you asked for',
    RecommendationReason.freeAtRequestedTime => 'free at that time',
    RecommendationReason.highestRated => 'best rated',
  };
}

/// One ranked result. [score] is exposed so tests can assert the ordering
/// rather than only its outcome.
class FacilityRecommendation {
  const FacilityRecommendation({
    required this.facility,
    required this.score,
    required this.matchedAmenities,
    required this.missingAmenities,
    required this.reasons,
  });

  final Facility facility;
  final double score;
  final List<String> matchedAmenities;
  final List<String> missingAmenities;
  final List<RecommendationReason> reasons;

  bool get isPartialMatch => missingAmenities.isNotEmpty;

  /// A one-line justification, e.g. "the right size · has everything you asked
  /// for". Empty when nothing notable applies.
  String get reasonLine => reasons.map((r) => r.label).join(' · ');
}

/// What the user asked for. Every field is optional: an empty criteria set
/// degrades to "rank the whole bookable catalogue sensibly".
class RecommendationCriteria {
  const RecommendationCriteria({
    this.minCapacity,
    this.category,
    this.amenities = const {},
    this.query,
  });

  final int? minCapacity;
  final String? category;
  final Set<String> amenities;
  final String? query;

  bool get isEmpty =>
      minCapacity == null &&
      category == null &&
      amenities.isEmpty &&
      (query == null || query!.trim().isEmpty);
}

// Weights. Amenities dominate because they are the most explicit thing a user
// states; rating is a tiebreak only, never a reason to beat a better fit.
const double _amenityWeight = 3;
const double _capacityWeight = 2;
const double _availabilityWeight = 2;
const double _categoryWeight = 2;
const double _ratingWeight = 1;

/// A facility more than this multiple of the requested headcount is treated as
/// oversized. Three times is generous enough to keep a 600-seat gym in play for
/// 200 people while still ranking a 220-seat hall above it.
const double _oversizeMultiple = 3;

/// Rank [pool] against [criteria].
///
/// [freeAtRequestedTime] is consulted only when a time window was actually
/// requested; pass null when the user named no time, so availability neither
/// helps nor hurts. Facilities that fail a *hard* requirement -- below the
/// requested capacity -- are dropped. A missing amenity is soft: the row
/// survives, ranked lower, with the gap recorded.
List<FacilityRecommendation> rankFacilities({
  required List<Facility> pool,
  required RecommendationCriteria criteria,
  bool Function(Facility facility)? freeAtRequestedTime,
  int limit = 5,
}) {
  if (pool.isEmpty) return const [];

  final requested = criteria.amenities;
  final minCapacity = criteria.minCapacity;
  final normalizedQuery = criteria.query?.trim().toLowerCase();

  final bestRating = pool
      .where((f) => f.hasRatings)
      .fold<double>(0, (best, f) => f.ratingAverage! > best ? f.ratingAverage! : best);

  final scored = <FacilityRecommendation>[];
  for (final facility in pool) {
    // Hard filter: a room that cannot hold the party is not a suggestion.
    if (minCapacity != null && facility.capacity < minCapacity) continue;

    // Hard filter: an explicit free-text name/room query must still match.
    if (normalizedQuery != null &&
        normalizedQuery.isNotEmpty &&
        !_matchesQuery(facility, normalizedQuery)) {
      continue;
    }

    final owned = facility.amenities.toSet();
    final matched = [for (final a in requested) if (owned.contains(a)) a]..sort();
    final missing = [for (final a in requested) if (!owned.contains(a)) a]..sort();

    final reasons = <RecommendationReason>[];
    var score = 0.0;

    if (requested.isNotEmpty) {
      score += _amenityWeight * (matched.length / requested.length);
      reasons.add(
        missing.isEmpty
            ? RecommendationReason.hasAllAmenities
            : RecommendationReason.missingAmenity,
      );
    }

    if (minCapacity != null && minCapacity > 0) {
      // Penalise oversizing so the smallest adequate room wins. A facility at
      // exactly the requested size scores 1; one at the oversize multiple or
      // beyond scores 0.
      final ratio = facility.capacity / minCapacity;
      final fit = ratio <= 1
          ? 1.0
          : (1 - (ratio - 1) / (_oversizeMultiple - 1)).clamp(0.0, 1.0);
      score += _capacityWeight * fit;
      reasons.add(
        ratio > _oversizeMultiple
            ? RecommendationReason.muchLarger
            : RecommendationReason.capacityFit,
      );
    }

    if (criteria.category != null) {
      if (facility.category == criteria.category) {
        score += _categoryWeight;
        reasons.add(RecommendationReason.categoryMatch);
      }
    }

    if (freeAtRequestedTime != null) {
      if (freeAtRequestedTime(facility)) {
        score += _availabilityWeight;
        reasons.add(RecommendationReason.freeAtRequestedTime);
      }
    }

    if (facility.hasRatings && bestRating > 0) {
      score += _ratingWeight * (facility.ratingAverage! / 5);
      if (facility.ratingAverage! >= bestRating) {
        reasons.add(RecommendationReason.highestRated);
      }
    }

    scored.add(
      FacilityRecommendation(
        facility: facility,
        score: score,
        matchedAmenities: matched,
        missingAmenities: missing,
        reasons: reasons,
      ),
    );
  }

  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    // Stable, explicable tiebreaks: smaller room first, then name.
    final byCapacity = a.facility.capacity.compareTo(b.facility.capacity);
    if (byCapacity != 0) return byCapacity;
    return a.facility.name.compareTo(b.facility.name);
  });

  return scored.take(limit).toList();
}

bool _matchesQuery(Facility facility, String query) =>
    facility.name.toLowerCase().contains(query) ||
    facility.room.toLowerCase().contains(query) ||
    facility.building.toLowerCase().contains(query) ||
    facility.category.toLowerCase().contains(query);
