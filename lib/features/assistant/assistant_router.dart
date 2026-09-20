/// Decides whether a message can be answered by rules or needs the cloud model.
///
/// This is the single most cost-sensitive decision in the assistant, so it
/// lives here as a pure function with no I/O: every routing choice is a test
/// case, and a question that silently starts costing money shows up as a failed
/// assertion rather than a bill. The rule is deliberately conservative -- when
/// rules can produce a correct, complete answer, they do, and the model is
/// reserved for phrasing the deterministic parser genuinely cannot classify.
library;

import 'assistant_nlu.dart';
import 'assistant_reference_frame.dart';

enum AssistantRouteKind {
  /// Answerable now, from rules and server-computed records. Costs nothing.
  ruleHandled,

  /// Send to the cloud model.
  escalate,

  /// Outside what the assistant does at all.
  outOfScope,
}

/// Why a message escalated. Recorded per request so the backlog of
/// `unknownIntent` turns can be converted into new rules over time -- the
/// mechanism by which model spend goes down rather than up.
enum EscalationReason {
  unknownIntent,
  unparsedBookingSlot,
  ambiguousReference,

  /// A booking request named a facility or activity the rules could not
  /// resolve to anything bookable. The rules can only offer an unfiltered
  /// list; naming the gap well is what the model is better at.
  unresolvedFacilityRequest,

  /// A question about what to book at all.
  ///
  /// The rules can filter and rank a catalogue they were handed, which is why
  /// [rankFacilities] stays the ordering authority. What they cannot do is
  /// decide that a pickleball game belongs in a Gymnasium, or say honestly
  /// that nothing here was ever built for one -- that needs a judgement about
  /// a word no dictionary in this repository will ever contain all of. Every
  /// such turn still falls back to its rule handler if the model is absent.
  discovery,
}

class AssistantRoute {
  const AssistantRoute._(this.kind, {this.intent, this.reason});

  const AssistantRoute.rule(AssistantIntent intent)
    : this._(AssistantRouteKind.ruleHandled, intent: intent);

  const AssistantRoute.escalate(EscalationReason reason)
    : this._(AssistantRouteKind.escalate, reason: reason);

  const AssistantRoute.outOfScope()
    : this._(AssistantRouteKind.outOfScope);

  final AssistantRouteKind kind;
  final AssistantIntent? intent;
  final EscalationReason? reason;

  bool get isRuleHandled => kind == AssistantRouteKind.ruleHandled;
  bool get isEscalation => kind == AssistantRouteKind.escalate;
}

/// Everything the router needs to know about the conversation, reduced to
/// primitives so the router never imports the controller (which imports it).
class AssistantRouteContext {
  const AssistantRouteContext({
    this.inBookingFlow = false,
    this.stageAccepted = false,
    this.assistsUsedForStage = 0,
    this.aiAvailable = false,
    this.facilityRequestUnresolved = false,
    this.facilityResolved = false,
    this.referenceFrame,
  });

  /// True while a booking draft is mid-slot-fill.
  final bool inBookingFlow;

  /// True when the deterministic parser produced something that fills the
  /// stage the draft is waiting on.
  final bool stageAccepted;

  /// How many model-assisted turns this stage has already consumed.
  final int assistsUsedForStage;

  final bool aiAvailable;

  /// True when the user named a facility or activity the catalogue cannot
  /// account for, so the rules can only offer an unfiltered list.
  final bool facilityRequestUnresolved;

  /// True when the message names exactly one bookable facility.
  ///
  /// Supplied by the caller rather than computed here so this stays a pure
  /// function with no `AppState` import, exactly as
  /// [facilityRequestUnresolved] already is.
  final bool facilityResolved;

  final AssistantReferenceFrame? referenceFrame;
}

/// Model-assisted turns allowed per booking stage before falling back to the
/// deterministic question and its picker sheet. Caps spend, and also stops a
/// model that keeps rephrasing instead of making progress.
const maxAssistsPerStage = 2;

/// Out-of-scope subjects the assistant refuses outright. Kept in step with
/// `AssistantController`'s own guard so the refusal is identical whichever
/// path reaches it.
const _outOfScopeCues = {
  'grade',
  'grades',
  'enroll',
  'enrollment',
  'tuition',
  'professor',
  'dean',
  'password',
};

final _inScopeCueRe = RegExp(
  r'\b(book|reserve|facility|facilities|room|rooms|venue|venues|available|'
  r'availability|reservation|reservations|cancel|permit|payment|balance|'
  r'equipment|announcement)\b',
);

AssistantRoute routeMessage(
  ParsedMessage parsed, {
  AssistantRouteContext context = const AssistantRouteContext(),
}) {
  // Scope is settled before anything else. "Reset my password" reads as an
  // abort cue to the parser, but it is a support question, and answering it
  // with "okay, dropped that" would be worse than saying it is not ours.
  if (_isOutOfScope(parsed.normalized)) return const AssistantRoute.outOfScope();

  // Dropping a draft is always a rule: it must work even with the model down.
  if (parsed.abort) return const AssistantRoute.rule(AssistantIntent.help);

  if (context.inBookingFlow) {
    // Inside a booking, the stage machine owns the conversation. The model is
    // consulted only when the parser cannot read the reply at all, and only
    // for a bounded number of turns -- after that the static question and its
    // picker sheet take over, which always work.
    if (context.stageAccepted) {
      return const AssistantRoute.rule(AssistantIntent.book);
    }
    if (context.aiAvailable &&
        context.assistsUsedForStage < maxAssistsPerStage) {
      return const AssistantRoute.escalate(
        EscalationReason.unparsedBookingSlot,
      );
    }
    return const AssistantRoute.rule(AssistantIntent.book);
  }

  if (parsed.intent == AssistantIntent.unknown) {
    return context.aiAvailable
        ? const AssistantRoute.escalate(EscalationReason.unknownIntent)
        : const AssistantRoute.rule(AssistantIntent.unknown);
  }

  // A booking we cannot attach to any facility is the one classified intent
  // worth a model call: the rules can only offer an unfiltered list, and
  // saying so well is exactly what the model is better at.
  if (parsed.intent == AssistantIntent.book &&
      context.aiAvailable &&
      context.facilityRequestUnresolved) {
    return const AssistantRoute.escalate(
      EscalationReason.unresolvedFacilityRequest,
    );
  }

  // Discovery -- "what should I book for X" -- is the class of question the
  // model exists for. Records questions (reservations, payments, permits,
  // policy) fall through to the rule handlers below, where they are already
  // exact, instant and free.
  if (context.aiAvailable && _isDiscovery(parsed, context)) {
    return const AssistantRoute.escalate(EscalationReason.discovery);
  }

  // Every other classified intent has a rule handler that either answers
  // outright or asks its own disambiguating question. Neither needs a model.
  return AssistantRoute.rule(parsed.intent);
}

bool _isDiscovery(ParsedMessage parsed, AssistantRouteContext context) {
  switch (parsed.intent) {
    case AssistantIntent.findFacilities:
    case AssistantIntent.recommendFacility:
      return true;
    case AssistantIntent.checkAvailability:
      // Only when the message did not pin down one facility. "Is the
      // Auditorium free Friday 2-4" is answered exactly, instantly and for
      // nothing by the rules; "what is free Friday afternoon" is the
      // open-ended one where the rule handler can only ask "Which one?" and
      // print eight unranked cards.
      return !context.facilityResolved;
    default:
      return false;
  }
}

bool _isOutOfScope(String normalized) {
  if (_inScopeCueRe.hasMatch(normalized)) return false;
  return _outOfScopeCues.any(normalized.contains);
}
