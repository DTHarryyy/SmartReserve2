import {
  assert,
  assertEquals,
  assertFalse,
  assertNotEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  AssistantProviderError,
  checkReply,
  collectFacilityIds,
  compactHistory,
  estimateTokens,
  extractChannels,
  isIsoDate,
  cacheKeyFor,
  isCacheable,
  isToolName,
  isUuid,
  maxHistoryTurns,
  maxMessageChars,
  maxReplyChars,
  maxReplyLines,
  maxReplySentences,
  maxSummaryChars,
  normalizeQuestion,
  permitBlockerMessage,
  redactedFields,
  redactForProvider,
  stripIdentityArguments,
  tidyReply,
  toolNames,
  toolSchemas,
  validateProposal,
  validateSlotFill,
  validateToolCall,
} from "./contract.ts";
import { parseCompletion } from "./openai.ts";
import { buildSystemPrompt } from "./prompt.ts";

import { pesoFromCentavos } from "./tools.ts";

const uuidA = "11111111-2222-3333-4444-555555555555";
const uuidB = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

// ---------------------------------------------------------------------------
// Tool registry
// ---------------------------------------------------------------------------

Deno.test("every declared tool has a schema", () => {
  for (const name of toolNames) {
    assert(toolSchemas[name], `${name} has no schema`);
    assertEquals(toolSchemas[name].type, "object");
    assertEquals(
      toolSchemas[name].additionalProperties,
      false,
      `${name} must not accept unexpected arguments`,
    );
  }
});

Deno.test("an unknown tool is rejected rather than dispatched", () => {
  assertFalse(isToolName("run_sql"));
  assertFalse(isToolName("get_all_reservations"));
  const error = assertThrows(
    () => validateToolCall("run_sql", "{}"),
    AssistantProviderError,
  );
  assertEquals((error as AssistantProviderError).code, "unknown_tool");
});

Deno.test("identity arguments are stripped, never honoured", () => {
  const { args, stripped } = stripIdentityArguments({
    reservation_id: uuidA,
    user_id: uuidB,
    email: "someone@example.com",
    role: "internal_admin",
  });
  assertEquals(args, { reservation_id: uuidA });
  assertEquals(stripped.sort(), ["email", "role", "user_id"]);
});

Deno.test("a tool call naming another user still runs as the caller", () => {
  // The model may ask; the identity simply does not travel with the call.
  const call = validateToolCall(
    "get_reservation_details",
    JSON.stringify({ reservation_id: uuidA, user_id: uuidB }),
  );
  assertEquals(call.args, { reservation_id: uuidA });
  assertEquals(call.strippedArguments, ["user_id"]);
});

Deno.test("invented identifiers are refused", () => {
  const error = assertThrows(
    () =>
      validateToolCall(
        "get_reservation_details",
        JSON.stringify({ reservation_id: "the-gym-booking" }),
      ),
    AssistantProviderError,
  );
  assertEquals((error as AssistantProviderError).code, "invalid_tool_argument");
});

Deno.test("missing and unexpected arguments are both caught", () => {
  assertEquals(
    (assertThrows(
      () => validateToolCall("get_reservation_details", "{}"),
      AssistantProviderError,
    ) as AssistantProviderError).code,
    "missing_tool_argument",
  );
  assertEquals(
    (assertThrows(
      () =>
        validateToolCall(
          "get_announcements",
          JSON.stringify({ limit: 500 }),
        ),
      AssistantProviderError,
    ) as AssistantProviderError).code,
    "unexpected_tool_argument",
  );
});

Deno.test("malformed argument JSON does not crash the turn", () => {
  assertEquals(
    (assertThrows(
      () => validateToolCall("get_my_reservations", "{not json"),
      AssistantProviderError,
    ) as AssistantProviderError).code,
    "invalid_tool_arguments",
  );
});

Deno.test("an empty argument string is treated as no arguments", () => {
  const call = validateToolCall("get_my_reservations", "");
  assertEquals(call.args, {});
});

Deno.test("dates must be real calendar dates", () => {
  assert(isIsoDate("2026-09-21"));
  assertFalse(isIsoDate("21/09/2026"));
  assertFalse(isIsoDate("tomorrow"));
  assertEquals(
    (assertThrows(
      () =>
        validateToolCall(
          "check_facility_availability",
          JSON.stringify({ facility_id: uuidA, day: "next friday" }),
        ),
      AssistantProviderError,
    ) as AssistantProviderError).code,
    "invalid_tool_argument",
  );
});

Deno.test("uuid detection is strict", () => {
  assert(isUuid(uuidA));
  assertFalse(isUuid("1234"));
  assertFalse(isUuid(`${uuidA}-extra`));
});

// ---------------------------------------------------------------------------
// Redaction
// ---------------------------------------------------------------------------

Deno.test("no redacted field survives a projection, at any depth", () => {
  const raw = {
    id: uuidA,
    facility_name: "Audio Visual Room",
    requester_name: "Jomar Padilla",
    email: "jomar@example.com",
    payments: [
      { amount: 100, reference_number: "GC-99887766", payer_id: uuidB },
    ],
    permit: {
      permit_number: "SR-2026-000029",
      verification_token: "secret-token",
      snapshot: { everything: true },
    },
  };
  const cleaned = JSON.stringify(redactForProvider(raw));

  for (const field of redactedFields) {
    assertFalse(
      cleaned.includes(field),
      `${field} must not reach the provider`,
    );
  }
  assertFalse(cleaned.includes("Jomar"));
  assertFalse(cleaned.includes("GC-99887766"));
  assertFalse(cleaned.includes("secret-token"));

  // What the assistant legitimately needs is still there.
  assert(cleaned.includes("Audio Visual Room"));
  assert(cleaned.includes("SR-2026-000029"));
});

Deno.test("redaction drops nulls and empties so they cost no tokens", () => {
  const cleaned = redactForProvider({
    id: uuidA,
    balance_due_at: null,
    amenities: [],
    note: "",
    keep: "yes",
  }) as Record<string, unknown>;
  assertEquals(Object.keys(cleaned).sort(), ["id", "keep"]);
});

Deno.test("redaction is depth-limited so a cycle cannot hang the turn", () => {
  const deep: Record<string, unknown> = {};
  let cursor = deep;
  for (let i = 0; i < 40; i++) {
    const next: Record<string, unknown> = {};
    cursor.next = next;
    cursor = next;
  }
  const cleaned = redactForProvider(deep);
  assert(JSON.stringify(cleaned).length < 500);
});

// ---------------------------------------------------------------------------
// History and budget
// ---------------------------------------------------------------------------

Deno.test("history is capped and each turn clipped", () => {
  const turns = Array.from({ length: 20 }, (_, index) => ({
    role: (index % 2 === 0 ? "user" : "assistant") as "user" | "assistant",
    content: "x".repeat(2000),
  }));
  const compacted = compactHistory(turns);
  assertEquals(compacted.length, maxHistoryTurns);
  for (const turn of compacted) {
    assertEquals(turn.content.length, maxMessageChars);
  }
});

Deno.test("empty turns are dropped rather than sent as blanks", () => {
  assertEquals(
    compactHistory([
      { role: "user", content: "  " },
      { role: "assistant", content: "Here you go." },
    ]).length,
    1,
  );
});

Deno.test("token estimation grows with length and is never negative", () => {
  assertEquals(estimateTokens(""), 0);
  assert(estimateTokens("a".repeat(350)) >= 100);
  assert(estimateTokens("short") < estimateTokens("short".repeat(50)));
});

// ---------------------------------------------------------------------------
// Response contract -- the anti-hallucination guard
// ---------------------------------------------------------------------------

const toolResult = JSON.stringify({
  id: uuidA,
  facility_name: "University Auditorium",
  outstanding: "₱3500",
  balance_due_at: "2026-09-21T17:00:00+08:00",
});

Deno.test("an amount that appears in a tool result is accepted", () => {
  const verdict = checkReply(
    "You still owe ₱3500 on University Auditorium.",
    [toolResult],
  );
  assert(verdict.ok, verdict.code);
});

Deno.test("an invented amount is rejected", () => {
  const verdict = checkReply(
    "You still owe ₱9999 on University Auditorium.",
    [toolResult],
  );
  assertFalse(verdict.ok);
  assertEquals(verdict.code, "ungrounded_amount");
});

Deno.test("centavos in the tool result ground pesos in the reply", () => {
  const verdict = checkReply(
    "Your balance is ₱1,750.",
    [JSON.stringify({ outstanding_amount_centavos: 175000 })],
  );
  assert(verdict.ok, verdict.code);
});

Deno.test("an amount with no tool results at all is rejected", () => {
  const verdict = checkReply("You owe ₱500.", []);
  assertFalse(verdict.ok);
});

Deno.test("raw backend errors never reach the user", () => {
  for (
    const leak of [
      "PostgrestException(message: permission denied)",
      "That failed: duplicate key value violates unique constraint",
      "AuthException while loading",
    ]
  ) {
    const verdict = checkReply(leak, [toolResult]);
    assertFalse(verdict.ok, leak);
    assertEquals(verdict.code, "backend_detail_leaked");
  }
});

Deno.test("a bare uuid in the reply is rejected", () => {
  const verdict = checkReply(`Your reservation ${uuidA} is confirmed.`, [
    toolResult,
  ]);
  assertFalse(verdict.ok);
  assertEquals(verdict.code, "raw_identifier_in_reply");
});

Deno.test("an over-long reply is rejected", () => {
  const verdict = checkReply("word ".repeat(400), [toolResult]);
  assertFalse(verdict.ok);
  assertEquals(verdict.code, "reply_too_long");
});

Deno.test("an empty reply is rejected", () => {
  assertEquals(checkReply("   ", [toolResult]).code, "empty_reply");
});

Deno.test("tidyReply collapses inline whitespace and clips a single paragraph to the sentence budget", () => {
  const tidied = tidyReply(
    "One.  Two. Three. Four. Five. Six. Seven. Eight.",
  );
  assertFalse(tidied.includes("  "));
  assertFalse(tidied.includes("Eight"));
  assert(tidied.length <= maxReplyChars);
});

Deno.test("tidyReply keeps a numbered list intact, one item per line", () => {
  const list = [
    "Here are facilities for 20 people:",
    "1. Volleyball Court - Capacity 30",
    "2. Basketball Court - Capacity 50",
    "3. Function Hall - Capacity 60",
    "4. Audio Visual Room - Capacity 100",
    "5. Gymnasium - Capacity 200",
  ].join("\n");
  const tidied = tidyReply(list);
  assertEquals(tidied.split("\n").length, 6);
  assert(tidied.includes("5. Gymnasium"));
});

Deno.test("tidyReply clips a long list by line, never mid-item", () => {
  const lines = ["Intro line:"];
  for (let i = 1; i <= 20; i++) lines.push(`${i}. Facility ${i}`);
  const tidied = tidyReply(lines.join("\n"));
  const tidiedLines = tidied.split("\n");
  assert(tidiedLines.length <= maxReplyLines);
  assertFalse(tidied.includes("Facility 20"));
  // Every surviving line is a whole item, never a fragment cut off mid-word.
  for (const line of tidiedLines) {
    assertFalse(line.endsWith("Facility"));
  }
});

Deno.test("tidyReply strips markdown the bubble cannot render", () => {
  const tidied = tidyReply(
    "**Volleyball Court** has *great* parking and __full__ Wi-Fi.",
  );
  assertFalse(tidied.includes("*"));
  assertFalse(tidied.includes("_"));
  assert(tidied.includes("Volleyball Court"));
});

Deno.test("tidyReply drops markdown headings", () => {
  const tidied = tidyReply("# Facilities\nVolleyball Court is free.");
  assertFalse(tidied.includes("#"));
});

Deno.test("tidyReply normalises dash and star bullets, leaves numbered lists alone", () => {
  const tidied = tidyReply(
    "Options:\n- Volleyball Court\n* Basketball Court\n1. Function Hall",
  );
  const lines = tidied.split("\n");
  assert(lines.includes("• Volleyball Court"));
  assert(lines.includes("• Basketball Court"));
  assert(lines.includes("1. Function Hall"));
});

Deno.test("tidyReply still strips a trailing json fence", () => {
  const tidied = tidyReply(
    'The AVR is free at 1pm.\n```json\n{"proposal":{"kind":"booking"}}\n```',
  );
  assertFalse(tidied.includes("proposal"));
  assertFalse(tidied.includes("```"));
});

// ---------------------------------------------------------------------------
// Money formatting parity with the Flutter client
// ---------------------------------------------------------------------------

Deno.test("peso formatting matches the app's own formatter", () => {
  // Mirrors pesoFromCentavos in lib/model/payment.dart: no thousands
  // separator, decimals only when they are not zero.
  assertEquals(pesoFromCentavos(350000), "₱3500");
  assertEquals(pesoFromCentavos(175000), "₱1750");
  assertEquals(pesoFromCentavos(0), "₱0");
  assertEquals(pesoFromCentavos(12345), "₱123.45");
});

// ---------------------------------------------------------------------------
// Output channels
// ---------------------------------------------------------------------------

Deno.test("a valid slot fill is accepted", () => {
  assertEquals(validateSlotFill({ slot: "date", day: "2026-09-22" }), {
    slot: "date",
    day: "2026-09-22",
  });
  assertEquals(
    validateSlotFill({ slot: "time", start_hour: 12, end_hour: 14 }),
    { slot: "time", start_hour: 12, end_hour: 14 },
  );
  assertEquals(validateSlotFill({ slot: "heads", heads: 30 }), {
    slot: "heads",
    heads: 30,
  });
});

Deno.test("slot fills that break a booking rule are refused", () => {
  // An end before a start, a fractional headcount, an off-grid time: all of
  // these are caught here as well as by the client's own validators.
  for (
    const bad of [
      { slot: "time", start_hour: 14, end_hour: 12 },
      { slot: "time", start_hour: 9.25, end_hour: 11 },
      { slot: "heads", heads: 12.5 },
      { slot: "heads", heads: 0 },
      { slot: "heads", heads: 99999 },
      { slot: "purpose", purpose: "x" },
      { slot: "facility", facility_id: "the gym" },
      { slot: "nonsense", value: 1 },
    ]
  ) {
    assertThrows(
      () => validateSlotFill(bad),
      AssistantProviderError,
      undefined,
      JSON.stringify(bad),
    );
  }
});

Deno.test("a purpose is trimmed and bounded", () => {
  const filled = validateSlotFill({
    slot: "purpose",
    purpose: `  ${"p".repeat(400)}  `,
  }) as { purpose: string };
  assertEquals(filled.purpose.length, 200);
});

Deno.test("a booking proposal must be complete and legal", () => {
  const proposal = validateProposal({
    kind: "booking",
    facility_id: uuidA,
    day: "2026-09-22",
    start_hour: 8,
    end_hour: 10,
    heads: 30,
    purpose: "Intramurals practice",
  });
  assertEquals(proposal.kind, "booking");

  assertThrows(
    () =>
      validateProposal({
        kind: "booking",
        facility_id: uuidA,
        day: "2026-09-22",
        start_hour: 8,
        end_hour: 10,
        heads: 30,
        // purpose missing
      }),
    AssistantProviderError,
  );
});

Deno.test("a cancellation proposal names a real reservation id", () => {
  assertEquals(
    validateProposal({ kind: "cancellation", reservation_id: uuidA }),
    { kind: "cancellation", reservation_id: uuidA },
  );
  assertThrows(
    () => validateProposal({ kind: "cancellation", reservation_id: "mine" }),
    AssistantProviderError,
  );
});

Deno.test("an unknown proposal kind is refused", () => {
  assertThrows(
    () => validateProposal({ kind: "delete_everything" }),
    AssistantProviderError,
  );
});

// ---------------------------------------------------------------------------
// Permit blockers: same wording as the client's PermitReadiness.messageFor
// ---------------------------------------------------------------------------

Deno.test("permit blocker codes map to the app's own wording", () => {
  assertEquals(
    permitBlockerMessage("full_payment_required"),
    "Full payment must be verified.",
  );
  assertEquals(
    permitBlockerMessage("requester_signature_required"),
    "Requester signature is required.",
  );
  // An unknown code still answers, rather than exposing the raw code.
  assertEquals(
    permitBlockerMessage("something_new_from_the_server"),
    "Official permit processing is incomplete.",
  );
});

// ---------------------------------------------------------------------------
// Response cache -- the rule that keeps it from becoming a data leak
// ---------------------------------------------------------------------------

Deno.test("only policy-only answers are cacheable", () => {
  assert(isCacheable(["get_policy_or_faq"]));
  assert(isCacheable(["get_policy_or_faq", "get_permit_requirements"]));
});

Deno.test("anything user-scoped is never cached", () => {
  // Caching one of these would serve one person's records to the next person
  // who phrased the question the same way.
  for (
    const tools of [
      ["get_payment_balance"],
      ["get_my_reservations"],
      ["get_policy_or_faq", "get_payment_balance"],
      ["get_reservation_details", "get_policy_or_faq"],
      ["get_announcements"],
      ["get_booking_draft_state"],
    ]
  ) {
    assertFalse(isCacheable(tools), tools.join(","));
  }
});

Deno.test("an answer grounded in no tool at all is not cached", () => {
  assertFalse(isCacheable([]));
});

Deno.test("trivial rephrasings share a cache key", async () => {
  const a = await cacheKeyFor("Can I cancel my reservation?", "guest", "1");
  const b = await cacheKeyFor("can i cancel my reservation", "guest", "1");
  assertEquals(a, b);
});

Deno.test("audience and knowledge version partition the cache", async () => {
  const base = await cacheKeyFor("what are the rules", "guest", "1");
  // Policy differs by lane, so the same question is a different entry.
  assertNotEquals(base, await cacheKeyFor("what are the rules", "student", "1"));
  // Editing the knowledge base invalidates answers that quoted it.
  assertNotEquals(base, await cacheKeyFor("what are the rules", "guest", "2"));
});

Deno.test("question normalization is punctuation and case insensitive", () => {
  assertEquals(
    normalizeQuestion("  Magkano   pa, bayad ko?! "),
    "magkano pa bayad ko",
  );
});

// ---------------------------------------------------------------------------
// Provider response parsing
// ---------------------------------------------------------------------------

Deno.test("a plain completion is parsed", () => {
  const result = parseCompletion({
    choices: [{ message: { content: "Hello." }, finish_reason: "stop" }],
    usage: { prompt_tokens: 120, completion_tokens: 8 },
  });
  assertEquals(result.content, "Hello.");
  assertEquals(result.toolCalls.length, 0);
  assertEquals(result.usage.inputTokens, 120);
});

Deno.test("tool calls are parsed, including object-shaped arguments", () => {
  const result = parseCompletion({
    choices: [{
      message: {
        content: null,
        tool_calls: [
          {
            id: "call_1",
            type: "function",
            function: {
              name: "get_payment_balance",
              arguments: `{"reservation_id":"${uuidA}"}`,
            },
          },
          {
            type: "function",
            function: { name: "get_announcements", arguments: {} },
          },
        ],
      },
      finish_reason: "tool_calls",
    }],
  });
  assertEquals(result.toolCalls.length, 2);
  assertEquals(result.toolCalls[0].function.name, "get_payment_balance");
  // A provider that omits an id still yields a usable call.
  assert(result.toolCalls[1].id.length > 0);
});

Deno.test("a malformed provider payload is a typed error", () => {
  for (const bad of [null, {}, { choices: [] }, { choices: [{}] }]) {
    assertThrows(() => parseCompletion(bad), AssistantProviderError);
  }
});

// ---------------------------------------------------------------------------
// Grounding: the gaps the response contract used to have
// ---------------------------------------------------------------------------

Deno.test("a thousands separator does not make a correct amount ungrounded", () => {
  // The tool layer formats pesos without separators. A model writing the
  // natural "₱3,500" against a result of "₱3500" was rejected, and the whole
  // turn downgraded to the rule-based answer -- a correct reply thrown away
  // for its punctuation.
  const verdict = checkReply(
    "You still owe ₱3,500 on University Auditorium.",
    [toolResult],
  );
  assert(verdict.ok, verdict.code);
});

Deno.test("a prefix of a grounded amount is not itself grounded", () => {
  // Substring matching accepted "₱35" against a haystack containing "₱3500":
  // wrong by two orders of magnitude, and on the reassuring side.
  const verdict = checkReply("You still owe ₱35.", [toolResult]);
  assertFalse(verdict.ok);
  assertEquals(verdict.code, "ungrounded_amount");
});

Deno.test("a date that appears in a tool result is accepted", () => {
  const verdict = checkReply(
    "Your balance is due on Fri, 25 Sep 2026.",
    [JSON.stringify({ balance_due_at: "Fri, 25 Sep 2026, 5:00 PM" })],
  );
  assert(verdict.ok, verdict.code);
});

Deno.test("an invented date is rejected", () => {
  // Dates were never checked, so the model could name any day at all and be
  // believed -- despite the prompt promising they arrive pre-formatted.
  const verdict = checkReply(
    "Your balance is due on Fri, 25 Dec 2026.",
    [JSON.stringify({ balance_due_at: "Fri, 25 Sep 2026, 5:00 PM" })],
  );
  assertFalse(verdict.ok);
  assertEquals(verdict.code, "ungrounded_date");
});

Deno.test("a date stated with no tool results at all is rejected", () => {
  const verdict = checkReply("It is due on 2026-09-25.", []);
  assertFalse(verdict.ok);
  assertEquals(verdict.code, "ungrounded_date");
});

Deno.test("the channel block never reaches the user", () => {
  // index.ts parses slot_fill and proposal from the RAW reply, so stripping
  // the fence here loses nothing -- and leaving it in meant the user read the
  // machinery along with the answer.
  const tidied = tidyReply(
    'Sure, booking the gym at 2pm.\n```json\n{"slot_fill":{"slot":"time","start_hour":14,"end_hour":16}}\n```',
  );
  assertEquals(tidied, "Sure, booking the gym at 2pm.");
  assertFalse(tidied.includes("slot_fill"));
});

Deno.test("an unterminated fence is still stripped", () => {
  const tidied = tidyReply('Booked.\n```json\n{"slot_fill":');
  assertEquals(tidied, "Booked.");
});

// ---------------------------------------------------------------------------
// Availability tools
// ---------------------------------------------------------------------------

Deno.test("get_available_facilities is registered and needs only a day", () => {
  assert(isToolName("get_available_facilities"));
  const schema = toolSchemas.get_available_facilities;
  assertEquals(schema.additionalProperties, false);
  assertEquals(schema.required, ["day"]);
});

Deno.test("an hour of day may be zero but not twenty-five", () => {
  // Midnight is a legal hour, so the old "must be > 0" numeric rule would
  // have refused it.
  const ok = validateToolCall("get_available_facilities", {
    day: "2026-09-25",
    from_hour: 0,
    to_hour: 12,
  });
  assertEquals(ok.args.from_hour, 0);

  assertThrows(
    () =>
      validateToolCall("get_available_facilities", {
        day: "2026-09-25",
        from_hour: 25,
      }),
    AssistantProviderError,
  );
});

Deno.test("schema bounds are enforced, not merely declared", () => {
  // The registry told the model 0.5 to 12 hours and then accepted anything.
  assertThrows(
    () =>
      validateToolCall("check_facility_availability", {
        facility_id: uuidA,
        day: "2026-09-25",
        duration_hours: 400,
      }),
    AssistantProviderError,
  );
  assertThrows(
    () =>
      validateToolCall("get_available_facilities", {
        day: "2026-09-25",
        min_capacity: 999999,
      }),
    AssistantProviderError,
  );
});

Deno.test("min_capacity must be whole, since half a person is not a capacity", () => {
  assertThrows(
    () =>
      validateToolCall("recommend_facilities", { min_capacity: 12.5 }),
    AssistantProviderError,
  );
});

// ---------------------------------------------------------------------------
// The rolling summary
// ---------------------------------------------------------------------------

Deno.test("the summary rides the channel block and never the answer", () => {
  const raw =
    'Your balance is settled.\n```json\n{"summary":"User is asking about the Gymplex booking on Friday."}\n```';
  const channels = extractChannels(raw);
  assertEquals(
    channels.summary,
    "User is asking about the Gymplex booking on Friday.",
  );
  // Same block the slot-fill channel uses, so it is stripped by the same rule.
  assertEquals(tidyReply(raw), "Your balance is settled.");
});

Deno.test("a summary is bounded, because it is sent on every later turn", () => {
  const long = "x".repeat(maxSummaryChars + 200);
  const channels = extractChannels(
    '```json\n' + JSON.stringify({ summary: long }) + '\n```',
  );
  assertEquals((channels.summary ?? "").length, maxSummaryChars);
});

Deno.test("a blank or non-string summary is no summary", () => {
  assertEquals(extractChannels('```json\n{"summary":"   "}\n```').summary, null);
  assertEquals(extractChannels('```json\n{"summary":42}\n```').summary, null);
  assertEquals(extractChannels("no block here").summary, null);
});

Deno.test("the summary channel coexists with a slot fill", () => {
  const channels = extractChannels(
    '```json\n{"fill_booking_slot":{"slot":"heads","heads":30},"summary":"Booking for 30."}\n```',
  );
  assertEquals(channels.summary, "Booking for 30.");
  assertEquals((channels.slotFill as { heads: number }).heads, 30);
});

Deno.test("a summary is only asked for once history outgrows the window", () => {
  const base = {
    lane: "external",
    pricingAudience: "guest",
    isAdmin: false,
    todayIso: "2026-09-20",
    inBookingFlow: false,
  };
  assertFalse(buildSystemPrompt(base).includes("summary"));
  assert(buildSystemPrompt({ ...base, wantsSummary: true }).includes("summary"));
});

// ---------------------------------------------------------------------------
// Facility ids surfaced for card rendering
// ---------------------------------------------------------------------------

Deno.test("collectFacilityIds reads ids from a facility-listing tool", () => {
  const result = { facilities: [{ id: uuidA }, { id: uuidB }] };
  assertEquals(collectFacilityIds("recommend_facilities", result), [
    uuidA,
    uuidB,
  ]);
  assertEquals(collectFacilityIds("get_available_facilities", result), [
    uuidA,
    uuidB,
  ]);
});

Deno.test("collectFacilityIds ignores every other tool", () => {
  const result = { facilities: [{ id: uuidA }] };
  assertEquals(collectFacilityIds("get_facility_details", result), []);
  assertEquals(collectFacilityIds("get_my_reservations", result), []);
});

Deno.test("collectFacilityIds tolerates a malformed or empty result", () => {
  assertEquals(collectFacilityIds("recommend_facilities", null), []);
  assertEquals(collectFacilityIds("recommend_facilities", {}), []);
  assertEquals(
    collectFacilityIds("recommend_facilities", { facilities: "not a list" }),
    [],
  );
  assertEquals(
    collectFacilityIds("recommend_facilities", {
      facilities: [{ id: "not-a-uuid" }, { name: "no id field" }],
    }),
    [],
  );
});

// ---------------------------------------------------------------------------
// Prompt/validator drift guard
//
// prompt.ts documents the fenced-JSON channel syntax in prose so the model
// knows the channel exists; contract.ts's validators are the only ground
// truth for what is actually accepted. This test pulls every example block
// out of the built system prompt and runs it through the real validators, so
// the two cannot silently drift apart.
// ---------------------------------------------------------------------------

Deno.test("every example JSON block in the system prompt validates for real", () => {
  const prompt = buildSystemPrompt({
    lane: "internal",
    pricingAudience: "student",
    isAdmin: false,
    todayIso: "2026-09-20",
    inBookingFlow: true,
  });

  // The prompt writes <uuid> and YYYY-MM-DD as human-readable placeholders
  // for the model, not literal values -- swapped for real ones so validation
  // checks shape and bounds rather than failing on the placeholder itself.
  const withRealValues = prompt.replace(/<uuid>/g, uuidA).replace(
    /YYYY-MM-DD/g,
    "2026-09-20",
  );
  const blocks = withRealValues.match(/```json\s*([\s\S]*?)```/g) ?? [];
  assert(blocks.length >= 3, "expected proposal + slot-fill examples");

  let sawProposal = false;
  let sawSlotFill = false;
  for (const block of blocks) {
    const inner = block.replace(/```json\s*/, "").replace(/```$/, "").trim();
    const parsed = JSON.parse(inner) as Record<string, unknown>;
    if (parsed.proposal) {
      validateProposal(parsed.proposal); // throws on the real mismatch
      sawProposal = true;
    }
    if (parsed.fill_booking_slot) {
      validateSlotFill(parsed.fill_booking_slot);
      sawSlotFill = true;
    }
  }
  assert(sawProposal, "prompt must show a valid proposal example");
  assert(sawSlotFill, "prompt must show a valid fill_booking_slot example");
});

Deno.test("every inline slot-fill example in the booking-flow prompt validates too", () => {
  const prompt = buildSystemPrompt({
    lane: "internal",
    pricingAudience: "student",
    isAdmin: false,
    todayIso: "2026-09-20",
    inBookingFlow: true,
  });

  // The facility example rides its own fenced block (covered above); date,
  // time, heads and purpose are shown inline as bare objects. None of these
  // slot shapes nest an object, so a flat, non-greedy brace match is exact.
  const withRealValues = prompt.replace(/<uuid>/g, uuidA).replace(
    /YYYY-MM-DD/g,
    "2026-09-20",
  );
  const inline = withRealValues.match(/\{"slot":"[a-z]+"[^{}]*\}/g) ?? [];
  const slotsSeen = new Set<string>();
  for (const raw of inline) {
    const parsed = validateSlotFill(JSON.parse(raw));
    slotsSeen.add(parsed.slot);
  }
  assertEquals(
    slotsSeen,
    new Set(["facility", "date", "time", "heads", "purpose"]),
  );
});
