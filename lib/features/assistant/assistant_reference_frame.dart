/// What "this one" and "the second one" refer to.
///
/// Follow-ups are resolved here, deterministically, before anything reaches a
/// language model: the model is handed an id that Dart already picked, never
/// asked to choose between records. When the frame cannot resolve a reference
/// the assistant asks, rather than guessing -- a wrong guess here would show
/// one reservation's balance under another's name.
library;

/// The result of trying to resolve a referring expression.
enum ReferenceOutcome {
  /// Exactly one candidate. [ReferenceResolution.id] is set.
  resolved,

  /// Nothing has been shown yet that the reference could point at.
  noCandidates,

  /// Several candidates and no ordinal to pick between them.
  ambiguous,

  /// An ordinal was given but it falls outside the list that was shown.
  outOfRange,
}

class ReferenceResolution {
  const ReferenceResolution(this.outcome, {this.id, this.candidateCount = 0});

  final ReferenceOutcome outcome;
  final String? id;
  final int candidateCount;

  bool get isResolved => outcome == ReferenceOutcome.resolved && id != null;

  static const none = ReferenceResolution(ReferenceOutcome.noCandidates);
}

/// The last things the assistant put on screen, in display order.
///
/// Ordinals index into these lists, so they must be updated every time a list
/// or detail card is rendered -- otherwise "the second one" silently refers to
/// a list the user can no longer see.
class AssistantReferenceFrame {
  List<String> reservationIds = const [];
  List<String> facilityIds = const [];

  /// The single record the conversation is currently "on", set when one
  /// reservation is shown on its own or picked out of a list.
  String? focusReservationId;
  String? focusFacilityId;

  bool get isEmpty =>
      reservationIds.isEmpty &&
      facilityIds.isEmpty &&
      focusReservationId == null &&
      focusFacilityId == null;

  void clear() {
    reservationIds = const [];
    facilityIds = const [];
    focusReservationId = null;
    focusFacilityId = null;
  }

  /// Record a list of reservations the user can now refer to by position.
  /// A single-item list also becomes the focus, since "it" is unambiguous.
  void noteReservations(List<String> ids) {
    reservationIds = List.unmodifiable(ids);
    if (ids.length == 1) focusReservationId = ids.first;
  }

  void noteFacilities(List<String> ids) {
    facilityIds = List.unmodifiable(ids);
    if (ids.length == 1) focusFacilityId = ids.first;
  }

  void noteReservationFocus(String id) {
    focusReservationId = id;
    if (!reservationIds.contains(id)) {
      reservationIds = List.unmodifiable([id]);
    }
  }

  void noteFacilityFocus(String id) {
    focusFacilityId = id;
    if (!facilityIds.contains(id)) {
      facilityIds = List.unmodifiable([id]);
    }
  }

  /// Resolve a reservation reference.
  ///
  /// [ordinal] is 1-based, as spoken ("the second one" -> 2).
  /// [available] narrows resolution to ids that are still valid for the action
  /// at hand -- the cancellable set, say -- so "cancel this one" cannot land on
  /// a reservation that has already started.
  ReferenceResolution resolveReservation({
    int? ordinal,
    List<String>? available,
  }) {
    final pool = available == null
        ? reservationIds
        : [
            for (final id in reservationIds)
              if (available.contains(id)) id,
          ];

    if (ordinal != null) {
      // An ordinal against an empty frame is still out of range, not "no
      // candidates" -- the user clearly meant to point at something.
      if (ordinal < 1 || ordinal > pool.length) {
        return ReferenceResolution(
          ReferenceOutcome.outOfRange,
          candidateCount: pool.length,
        );
      }
      return ReferenceResolution(
        ReferenceOutcome.resolved,
        id: pool[ordinal - 1],
        candidateCount: pool.length,
      );
    }

    final focus = focusReservationId;
    if (focus != null && (available == null || available.contains(focus))) {
      return ReferenceResolution(
        ReferenceOutcome.resolved,
        id: focus,
        candidateCount: pool.length,
      );
    }

    if (pool.isEmpty) return ReferenceResolution.none;
    if (pool.length == 1) {
      return ReferenceResolution(
        ReferenceOutcome.resolved,
        id: pool.first,
        candidateCount: 1,
      );
    }
    return ReferenceResolution(
      ReferenceOutcome.ambiguous,
      candidateCount: pool.length,
    );
  }

  ReferenceResolution resolveFacility({int? ordinal}) {
    if (ordinal != null) {
      if (ordinal < 1 || ordinal > facilityIds.length) {
        return ReferenceResolution(
          ReferenceOutcome.outOfRange,
          candidateCount: facilityIds.length,
        );
      }
      return ReferenceResolution(
        ReferenceOutcome.resolved,
        id: facilityIds[ordinal - 1],
        candidateCount: facilityIds.length,
      );
    }
    final focus = focusFacilityId;
    if (focus != null) {
      return ReferenceResolution(
        ReferenceOutcome.resolved,
        id: focus,
        candidateCount: facilityIds.length,
      );
    }
    if (facilityIds.isEmpty) return ReferenceResolution.none;
    if (facilityIds.length == 1) {
      return ReferenceResolution(
        ReferenceOutcome.resolved,
        id: facilityIds.first,
        candidateCount: 1,
      );
    }
    return ReferenceResolution(
      ReferenceOutcome.ambiguous,
      candidateCount: facilityIds.length,
    );
  }

  /// Compact ids for the AI context block. Never labels, never records --
  /// the model receives only what it needs to name a row back to us.
  Map<String, dynamic> toContextPayload() => {
    if (reservationIds.isNotEmpty)
      'recent_reservation_ids': reservationIds.take(10).toList(),
    if (facilityIds.isNotEmpty)
      'recent_facility_ids': facilityIds.take(10).toList(),
    if (focusReservationId != null) 'focus_reservation_id': focusReservationId,
    if (focusFacilityId != null) 'focus_facility_id': focusFacilityId,
  };
}
