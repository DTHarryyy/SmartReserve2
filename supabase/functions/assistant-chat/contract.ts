// Pure logic for the assistant's cloud-model turn. No I/O, no Supabase import,
// no fetch -- so every rule below is unit-testable without a server, in the
// same shape as generate-permit/contract.ts and feedback-sentiment/contract.ts.
//
// Three jobs live here:
//   1. Declaring what the model may call, and validating what it asks for.
//   2. Redacting what may be sent outward, as code rather than as policy.
//   3. Checking what comes back, so a fluent answer that is not grounded in
//      this turn's tool results never reaches a user.

export class AssistantProviderError extends Error {
  constructor(
    readonly code: string,
    message = code,
    readonly retryAfterSeconds?: number,
    readonly terminal = false,
  ) {
    super(message);
    this.name = "AssistantProviderError";
  }
}

// Copied deliberately from feedback-sentiment/contract.ts rather than shared:
// supabase/functions has no _shared directory, and introducing one as a side
// effect of this feature would touch four unrelated deployed functions.
export function sanitizeErrorCode(value: unknown): string {
  const raw = typeof value === "string" && value.trim().length > 0
    ? value.trim().toLowerCase()
    : "assistant_failed";
  const normalized = raw.replace(/[^a-z0-9_]+/g, "_").replace(/^_+|_+$/g, "")
    .slice(0, 80);
  return normalized.length >= 2 ? normalized : "assistant_failed";
}

export function parsePositiveInt(
  value: string | undefined,
  fallback: number,
  min: number,
  max: number,
): number {
  const parsed = Number.parseInt(value ?? "", 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, parsed));
}

export function retryAfterSeconds(header: string | null): number | undefined {
  if (!header) return undefined;
  const seconds = Number.parseInt(header, 10);
  if (Number.isFinite(seconds)) return Math.max(1, Math.min(seconds, 1800));
  const date = Date.parse(header);
  if (!Number.isFinite(date)) return undefined;
  return Math.max(1, Math.min(Math.ceil((date - Date.now()) / 1000), 1800));
}

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

/** Chat turns replayed to the model. Older turns collapse into a summary. */
export const maxHistoryTurns = 6;

/** Per-message cap, matching the 500-character cap the Dart parser applies. */
export const maxMessageChars = 500;

/** Tool rounds per request, and calls per round. A hard ceiling on spend. */
export const maxToolRounds = 2;
export const maxToolCallsPerRound = 3;

/** Sentences an answer may run to before it is treated as over-long. */
export const maxReplySentences = 5;
export const maxReplyChars = 700;

/**
 * The rolling summary's budget.
 *
 * It is sent on every subsequent turn of the conversation, so it has to be
 * cheaper than the turns it replaces or it is not an optimisation. The column
 * that stores it caps at 1000; this is tighter on purpose.
 */
export const maxSummaryChars = 400;

/**
 * Turns of history after which the model is asked to keep a summary.
 *
 * Below this the six-turn window holds the whole conversation and a summary
 * would restate what is already there, at the cost of output tokens every
 * turn.
 */
export const summaryAfterTurns = 6;

// ---------------------------------------------------------------------------
// Tool registry declaration
//
// The model can only ask for a name in this table. Anything else is answered
// with an error tool result rather than dispatched -- there is no dynamic
// lookup anywhere in the pipeline.
// ---------------------------------------------------------------------------

export type ToolName =
  | "get_my_reservations"
  | "get_upcoming_reservations"
  | "get_reservation_details"
  | "get_reservation_status"
  | "check_facility_availability"
  | "get_available_facilities"
  | "get_facility_details"
  | "get_payment_balance"
  | "get_payment_status"
  | "get_payment_deadline"
  | "get_permit_status"
  | "get_permit_requirements"
  | "get_equipment_availability"
  | "get_announcements"
  | "get_policy_or_faq"
  | "get_booking_draft_state"
  | "recommend_facilities";

export const toolNames: readonly ToolName[] = [
  "get_my_reservations",
  "get_upcoming_reservations",
  "get_reservation_details",
  "get_reservation_status",
  "check_facility_availability",
  "get_available_facilities",
  "get_facility_details",
  "get_payment_balance",
  "get_payment_status",
  "get_payment_deadline",
  "get_permit_status",
  "get_permit_requirements",
  "get_equipment_availability",
  "get_announcements",
  "get_policy_or_faq",
  "get_booking_draft_state",
  "recommend_facilities",
] as const;

const toolNameSet = new Set<string>(toolNames);

export function isToolName(value: unknown): value is ToolName {
  return typeof value === "string" && toolNameSet.has(value);
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && uuidPattern.test(value);
}

const isoDatePattern = /^\d{4}-\d{2}-\d{2}$/;

export function isIsoDate(value: unknown): value is string {
  if (typeof value !== "string" || !isoDatePattern.test(value)) return false;
  const parsed = Date.parse(`${value}T00:00:00Z`);
  return Number.isFinite(parsed);
}

// Arguments that would let the model choose whose data to read. These are
// stripped before validation rather than rejected, because a model that tries
// is common and harmless -- the identity always comes from the verified JWT.
const identityArgumentNames = new Set([
  "user_id",
  "userid",
  "requester_id",
  "owner_id",
  "profile_id",
  "account_id",
  "auth_id",
  "email",
  "role",
  "lane",
  "admin_lane",
  "pricing_audience",
]);

export function stripIdentityArguments(
  args: Record<string, unknown>,
): { args: Record<string, unknown>; stripped: string[] } {
  const kept: Record<string, unknown> = {};
  const stripped: string[] = [];
  for (const [key, value] of Object.entries(args)) {
    if (identityArgumentNames.has(key.toLowerCase())) {
      stripped.push(key);
      continue;
    }
    kept[key] = value;
  }
  return { args: kept, stripped };
}

/** JSON Schemas handed to the provider, one per tool. */
export const toolSchemas: Record<ToolName, Record<string, unknown>> = {
  get_my_reservations: {
    type: "object",
    additionalProperties: false,
    properties: {},
  },
  get_upcoming_reservations: {
    type: "object",
    additionalProperties: false,
    properties: {},
  },
  get_reservation_details: {
    type: "object",
    additionalProperties: false,
    properties: {
      reservation_id: { type: "string", description: "Id from a prior result" },
    },
    required: ["reservation_id"],
  },
  get_reservation_status: {
    type: "object",
    additionalProperties: false,
    properties: { reservation_id: { type: "string" } },
    required: ["reservation_id"],
  },
  check_facility_availability: {
    type: "object",
    additionalProperties: false,
    properties: {
      facility_id: { type: "string" },
      day: { type: "string", description: "YYYY-MM-DD" },
      duration_hours: { type: "number", minimum: 0.5, maximum: 12 },
      from_hour: { type: "number", minimum: 0, maximum: 24 },
      to_hour: { type: "number", minimum: 0, maximum: 24 },
    },
    required: ["facility_id", "day"],
  },
  get_available_facilities: {
    type: "object",
    additionalProperties: false,
    properties: {
      day: { type: "string", description: "YYYY-MM-DD" },
      // Hours are 24-hour decimals: 13.5 is 1:30 PM. "Afternoon" is 13 to 17.
      from_hour: { type: "number", minimum: 0, maximum: 24 },
      to_hour: { type: "number", minimum: 0, maximum: 24 },
      duration_hours: { type: "number", minimum: 0.5, maximum: 12 },
      min_capacity: { type: "number", minimum: 1, maximum: 5000 },
      category: { type: "string" },
    },
    required: ["day"],
  },
  get_facility_details: {
    type: "object",
    additionalProperties: false,
    properties: { facility_id: { type: "string" } },
    required: ["facility_id"],
  },
  get_payment_balance: {
    type: "object",
    additionalProperties: false,
    properties: { reservation_id: { type: "string" } },
    required: ["reservation_id"],
  },
  get_payment_status: {
    type: "object",
    additionalProperties: false,
    properties: { reservation_id: { type: "string" } },
    required: ["reservation_id"],
  },
  get_payment_deadline: {
    type: "object",
    additionalProperties: false,
    properties: { reservation_id: { type: "string" } },
    required: ["reservation_id"],
  },
  get_permit_status: {
    type: "object",
    additionalProperties: false,
    properties: { reservation_id: { type: "string" } },
    required: ["reservation_id"],
  },
  get_permit_requirements: {
    type: "object",
    additionalProperties: false,
    properties: {
      template_kind: { type: "string", enum: ["internal", "external"] },
    },
  },
  get_equipment_availability: {
    type: "object",
    additionalProperties: false,
    properties: {
      facility_id: { type: "string" },
      day: { type: "string", description: "YYYY-MM-DD" },
    },
    required: ["facility_id"],
  },
  get_announcements: {
    type: "object",
    additionalProperties: false,
    properties: {},
  },
  get_policy_or_faq: {
    type: "object",
    additionalProperties: false,
    properties: {
      query: { type: "string", description: "The user's question, verbatim" },
    },
    required: ["query"],
  },
  get_booking_draft_state: {
    type: "object",
    additionalProperties: false,
    properties: {},
  },
  recommend_facilities: {
    type: "object",
    additionalProperties: false,
    properties: {
      min_capacity: { type: "integer", minimum: 1, maximum: 5000 },
      category: { type: "string" },
      amenities: {
        type: "array",
        items: { type: "string" },
        maxItems: 6,
      },
    },
  },
};

export type ValidatedToolCall = {
  name: ToolName;
  args: Record<string, unknown>;
  strippedArguments: string[];
};

/**
 * Validate one tool call.
 *
 * Throws with a stable code rather than returning null so the caller can turn
 * the failure into a tool result the model can recover from, instead of
 * failing the whole turn.
 */
export function validateToolCall(
  name: unknown,
  rawArgs: unknown,
): ValidatedToolCall {
  if (!isToolName(name)) {
    throw new AssistantProviderError("unknown_tool", `Unknown tool: ${name}`);
  }

  let parsed: unknown = rawArgs;
  if (typeof rawArgs === "string") {
    try {
      parsed = rawArgs.trim() === "" ? {} : JSON.parse(rawArgs);
    } catch (_) {
      throw new AssistantProviderError("invalid_tool_arguments");
    }
  }
  if (parsed === null || parsed === undefined) parsed = {};
  if (typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new AssistantProviderError("invalid_tool_arguments");
  }

  const { args, stripped } = stripIdentityArguments(
    parsed as Record<string, unknown>,
  );
  const schema = toolSchemas[name];
  const properties = (schema.properties ?? {}) as Record<string, unknown>;
  const required = (schema.required ?? []) as string[];

  for (const key of Object.keys(args)) {
    if (!(key in properties)) {
      throw new AssistantProviderError("unexpected_tool_argument", key);
    }
  }
  for (const key of required) {
    if (args[key] === undefined || args[key] === null) {
      throw new AssistantProviderError("missing_tool_argument", key);
    }
  }

  // Types the registry cares about. Ids must be real uuids, because the only
  // legitimate source for one is a previous tool result -- a model that
  // invents an id should fail here rather than at the database.
  for (const [key, value] of Object.entries(args)) {
    const property = (properties[key] ?? {}) as Record<string, unknown>;

    if (key.endsWith("_id")) {
      if (!isUuid(value)) {
        throw new AssistantProviderError("invalid_tool_argument", key);
      }
    } else if (key === "day") {
      if (!isIsoDate(value)) {
        throw new AssistantProviderError("invalid_tool_argument", key);
      }
    } else if (property.type === "number" || property.type === "integer") {
      // Bounds come from the schema rather than a hand-written list, so a new
      // numeric argument is range-checked the moment it is declared. They were
      // previously advisory: the model was told 0.5 to 12 hours and could send
      // 400, and an hour-of-day argument cannot use a "> 0" rule because
      // midnight is 0.
      if (typeof value !== "number" || !Number.isFinite(value)) {
        throw new AssistantProviderError("invalid_tool_argument", key);
      }
      if (property.type === "integer" && !Number.isInteger(value)) {
        throw new AssistantProviderError("invalid_tool_argument", key);
      }
      if (typeof property.minimum === "number" && value < property.minimum) {
        throw new AssistantProviderError("invalid_tool_argument", key);
      }
      if (typeof property.maximum === "number" && value > property.maximum) {
        throw new AssistantProviderError("invalid_tool_argument", key);
      }
    } else if (key === "amenities") {
      if (
        !Array.isArray(value) || value.length > 6 ||
        value.some((item) => typeof item !== "string")
      ) {
        throw new AssistantProviderError("invalid_tool_argument", key);
      }
    } else if (typeof value !== "string" && typeof value !== "number") {
      throw new AssistantProviderError("invalid_tool_argument", key);
    }
  }

  return { name, args, strippedArguments: stripped };
}

// ---------------------------------------------------------------------------
// Redaction
//
// README commits that SmartReserve sends no identities to a model provider.
// A chatbot answering "how much do I owe" necessarily widens that, so the
// boundary is drawn here, in code, and asserted in contract_test.ts: schedule,
// facility, status and amount may leave; who you are may not.
// ---------------------------------------------------------------------------

export const redactedFields = [
  "requester_name",
  "requester",
  "full_name",
  "email",
  "campus_id",
  "campus_claim",
  "contact_numbers",
  "external_contact_numbers",
  "external_complete_address",
  "reference_number",
  "proof_path",
  "storage_path",
  "verification_token",
  "pdf_sha256",
  "content_hash",
  "snapshot",
  "requester_id",
  "payer_id",
  "owner_id",
  "decided_by",
  "issued_by",
  "delivered_by",
  "user_signature_id",
  "internal_approver_signature_id",
  "external_recommender_signature_id",
  "external_authorized_signature_id",
  "ceo_signature_id",
] as const;

const redactedSet = new Set<string>(redactedFields);

/**
 * Strip identifying and sensitive fields from anything about to be sent
 * outward, at any nesting depth. Also drops nulls and empty collections --
 * a null costs tokens and tells the model nothing.
 */
export function redactForProvider(value: unknown, depth = 0): unknown {
  if (depth > 8) return null;
  if (Array.isArray(value)) {
    const mapped = value
      .map((item) => redactForProvider(item, depth + 1))
      .filter((item) => item !== null && item !== undefined);
    return mapped;
  }
  if (value === null || typeof value !== "object") return value;

  const out: Record<string, unknown> = {};
  for (const [key, raw] of Object.entries(value as Record<string, unknown>)) {
    if (redactedSet.has(key.toLowerCase())) continue;
    const cleaned = redactForProvider(raw, depth + 1);
    if (cleaned === null || cleaned === undefined) continue;
    if (Array.isArray(cleaned) && cleaned.length === 0) continue;
    if (typeof cleaned === "string" && cleaned.length === 0) continue;
    out[key] = cleaned;
  }
  return out;
}

// ---------------------------------------------------------------------------
// History compaction
// ---------------------------------------------------------------------------

export type ChatTurn = { role: "user" | "assistant"; content: string };

export function compactHistory(
  turns: readonly ChatTurn[],
  limit = maxHistoryTurns,
): ChatTurn[] {
  const recent = turns.slice(-limit);
  return recent
    .filter((turn) => typeof turn.content === "string" && turn.content.trim())
    .map((turn) => ({
      role: turn.role,
      content: turn.content.trim().slice(0, maxMessageChars),
    }));
}

/**
 * Rough token estimate. Deliberately conservative and dependency-free: it
 * exists to refuse an oversized request before paying for it, not to bill.
 */
export function estimateTokens(text: string): number {
  if (!text) return 0;
  return Math.ceil(text.length / 3.5);
}

export function estimateMessagesTokens(
  messages: readonly { content?: string | null }[],
): number {
  let total = 0;
  for (const message of messages) {
    total += estimateTokens(message.content ?? "") + 4;
  }
  return total;
}

// ---------------------------------------------------------------------------
// Response contract
//
// The model is instructed to restate tool results, never to compute. This is
// where that instruction becomes enforceable: any peso amount or date in the
// reply must also appear in a tool result from the same turn. A reply that
// fails is downgraded to the rule-based fallback rather than shipped.
// ---------------------------------------------------------------------------

export type ReplyCheck = {
  ok: boolean;
  code?: string;
  detail?: string;
};

const pesoPattern = /₱\s?[\d,]+(?:\.\d{1,2})?/g;
const backendLeakPattern =
  /PostgrestException|AuthException|StorageException|FunctionException|SQLSTATE|pg_|relation "|duplicate key|violates (?:check|foreign key|not-null)/i;
const bareUuidPattern =
  /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i;

function normalizeAmount(value: string): string {
  return value.replace(/[₱,\s]/g, "");
}

// Every number a reply is allowed to state, as values rather than substrings.
//
// Substring matching made "₱35" grounded by a tool result containing "₱3500":
// wrong by two orders of magnitude, on the reassuring side, and it passed.
//
// The peso/centavos equivalence is deliberately narrow. Only a value that came
// from a field actually named *_centavos is also offered in pesos; dividing
// every integer by a hundred would re-introduce exactly the ambiguity above,
// making "₱35" grounded by "3500" again.
function addNumber(found: Set<string>, raw: string): void {
  const plain = raw.replace(/,/g, "");
  if (!plain) return;
  found.add(plain);
  const asNumber = Number(plain);
  if (Number.isFinite(asNumber)) found.add(String(asNumber));
}

function collectNumbers(found: Set<string>, value: unknown, key = ""): void {
  if (typeof value === "number") {
    addNumber(found, String(value));
    if (key.endsWith("_centavos") && Number.isInteger(value)) {
      addNumber(found, String(value / 100));
      found.add((value / 100).toFixed(2));
    }
    return;
  }
  if (typeof value === "string") {
    for (const raw of value.match(/\d[\d,]*(?:\.\d+)?/g) ?? []) {
      addNumber(found, raw);
    }
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectNumbers(found, item, key);
    return;
  }
  if (value && typeof value === "object") {
    for (const [childKey, child] of Object.entries(value)) {
      collectNumbers(found, child, childKey);
    }
  }
}

function groundedNumbers(toolResultsJson: readonly string[]): Set<string> {
  const found = new Set<string>();
  for (const json of toolResultsJson) {
    try {
      collectNumbers(found, JSON.parse(json));
    } catch (_) {
      // Not JSON after all; fall back to a flat scan so a malformed result
      // cannot turn every amount in the reply into a rejection.
      for (const raw of json.match(/\d[\d,]*(?:\.\d+)?/g) ?? []) {
        addNumber(found, raw);
      }
    }
  }
  return found;
}

// Dates the model might state back. Covers the formatted forms the tool layer
// emits ("Fri, 25 Sep 2026", "25 Sep 2026") and bare ISO.
const datePattern =
  /\b(?:\d{4}-\d{2}-\d{2}|\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{4}|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2},?\s+\d{4})\b/gi;

function normalizeDate(value: string): string {
  return value.replace(/[.,]/g, "").replace(/\s+/g, " ").trim().toLowerCase();
}

export function checkReply(
  reply: string,
  toolResultsJson: readonly string[],
): ReplyCheck {
  const text = (reply ?? "").trim();
  if (!text) return { ok: false, code: "empty_reply" };
  if (text.length > maxReplyChars) {
    return { ok: false, code: "reply_too_long", detail: `${text.length}` };
  }
  if (backendLeakPattern.test(text)) {
    return { ok: false, code: "backend_detail_leaked" };
  }
  // References are how a reservation is named to a user; a raw uuid is both
  // meaningless to them and a sign the model is echoing plumbing.
  if (bareUuidPattern.test(text)) {
    return { ok: false, code: "raw_identifier_in_reply" };
  }

  const haystack = toolResultsJson.join("\n");
  const numbers = groundedNumbers(toolResultsJson);

  const amounts = text.match(pesoPattern) ?? [];
  for (const amount of amounts) {
    const normalized = normalizeAmount(amount);
    const asNumber = Number(normalized);
    if (!Number.isFinite(asNumber)) {
      return { ok: false, code: "ungrounded_amount", detail: amount };
    }
    // Compare values, not text. The tool layer formats pesos without
    // separators, so a model writing the natural "₱3,500" against a result of
    // "₱3500" used to be thrown away and the whole turn downgraded to the
    // rule-based answer -- a correct reply rejected for its punctuation.
    //
    // The peso/centavos equivalence is applied to the tool result only, by
    // groundedNumbers, and never to the reply: multiplying the reply by a
    // hundred would let "₱35" match a result of 3500 centavos, which is the
    // ambiguity this check exists to catch.
    if (
      !numbers.has(normalized) && !numbers.has(String(asNumber)) &&
      !numbers.has(asNumber.toFixed(2))
    ) {
      return { ok: false, code: "ungrounded_amount", detail: amount };
    }
  }

  // Dates get the same treatment as amounts. The header of this file and the
  // system prompt both promised it; only amounts were ever checked, so the
  // model could state any date at all and be believed.
  const normalizedHaystack = normalizeDate(haystack);
  for (const date of text.match(datePattern) ?? []) {
    if (!normalizedHaystack.includes(normalizeDate(date))) {
      return { ok: false, code: "ungrounded_date", detail: date };
    }
  }

  return { ok: true };
}

/**
 * Collapse whitespace and clip to the sentence budget.
 *
 * Fenced blocks go first. The slot-fill and proposal channels arrive as a
 * ```json block appended to the answer, and index.ts parses those from the RAW
 * reply -- so nothing here needs them, and leaving them in meant the user read
 * the machinery along with the answer.
 */
export function tidyReply(reply: string): string {
  const withoutFences = (reply ?? "").replace(/```[\s\S]*?(?:```|$)/g, " ");
  const collapsed = withoutFences.replace(/\s+/g, " ").trim();
  const sentences = collapsed.match(/[^.!?]+[.!?]*/g) ?? [collapsed];
  if (sentences.length <= maxReplySentences) return collapsed;
  return sentences.slice(0, maxReplySentences).join("").trim();
}

// ---------------------------------------------------------------------------
// Client-proposed output channels
//
// The model may propose a booking slot value or a write. None of these are
// executed here: they are returned as data and applied by the Flutter client
// through the same validators a typed or tapped value goes through.
// ---------------------------------------------------------------------------

export type BookingSlot = "facility" | "date" | "time" | "heads" | "purpose";

export const bookingSlots: readonly BookingSlot[] = [
  "facility",
  "date",
  "time",
  "heads",
  "purpose",
] as const;

export type SlotFill =
  | { slot: "facility"; facility_id: string }
  | { slot: "date"; day: string }
  | { slot: "time"; start_hour: number; end_hour: number }
  | { slot: "heads"; heads: number }
  | { slot: "purpose"; purpose: string };

export function validateSlotFill(value: unknown): SlotFill {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new AssistantProviderError("invalid_slot_fill");
  }
  const record = value as Record<string, unknown>;
  const slot = record.slot;
  if (typeof slot !== "string" || !bookingSlots.includes(slot as BookingSlot)) {
    throw new AssistantProviderError("invalid_slot_fill", "slot");
  }

  switch (slot) {
    case "facility": {
      if (!isUuid(record.facility_id)) {
        throw new AssistantProviderError("invalid_slot_fill", "facility_id");
      }
      return { slot: "facility", facility_id: record.facility_id as string };
    }
    case "date": {
      if (!isIsoDate(record.day)) {
        throw new AssistantProviderError("invalid_slot_fill", "day");
      }
      return { slot: "date", day: record.day as string };
    }
    case "time": {
      const start = record.start_hour;
      const end = record.end_hour;
      if (
        typeof start !== "number" || typeof end !== "number" ||
        !Number.isFinite(start) || !Number.isFinite(end) ||
        start < 0 || end > 24 || end <= start
      ) {
        throw new AssistantProviderError("invalid_slot_fill", "time");
      }
      // Half-hour grid, matching the picker and the slot engine.
      if ((start * 2) % 1 !== 0 || (end * 2) % 1 !== 0) {
        throw new AssistantProviderError("invalid_slot_fill", "time_grid");
      }
      return { slot: "time", start_hour: start, end_hour: end };
    }
    case "heads": {
      const heads = record.heads;
      if (
        typeof heads !== "number" || !Number.isInteger(heads) ||
        heads < 1 || heads > 5000
      ) {
        throw new AssistantProviderError("invalid_slot_fill", "heads");
      }
      return { slot: "heads", heads };
    }
    default: {
      const purpose = record.purpose;
      if (typeof purpose !== "string" || purpose.trim().length < 3) {
        throw new AssistantProviderError("invalid_slot_fill", "purpose");
      }
      return { slot: "purpose", purpose: purpose.trim().slice(0, 200) };
    }
  }
}

export type AssistantProposal =
  | {
    kind: "booking";
    facility_id: string;
    day: string;
    start_hour: number;
    end_hour: number;
    heads: number;
    purpose: string;
  }
  | { kind: "cancellation"; reservation_id: string };

export function validateProposal(value: unknown): AssistantProposal {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new AssistantProviderError("invalid_proposal");
  }
  const record = value as Record<string, unknown>;
  if (record.kind === "cancellation") {
    if (!isUuid(record.reservation_id)) {
      throw new AssistantProviderError("invalid_proposal", "reservation_id");
    }
    return {
      kind: "cancellation",
      reservation_id: record.reservation_id as string,
    };
  }
  if (record.kind !== "booking") {
    throw new AssistantProviderError("invalid_proposal", "kind");
  }

  const time = validateSlotFill({
    slot: "time",
    start_hour: record.start_hour,
    end_hour: record.end_hour,
  }) as { start_hour: number; end_hour: number };
  const heads = validateSlotFill({ slot: "heads", heads: record.heads }) as {
    heads: number;
  };
  const purpose = validateSlotFill({
    slot: "purpose",
    purpose: record.purpose,
  }) as { purpose: string };

  if (!isUuid(record.facility_id)) {
    throw new AssistantProviderError("invalid_proposal", "facility_id");
  }
  if (!isIsoDate(record.day)) {
    throw new AssistantProviderError("invalid_proposal", "day");
  }

  return {
    kind: "booking",
    facility_id: record.facility_id as string,
    day: record.day as string,
    start_hour: time.start_hour,
    end_hour: time.end_hour,
    heads: heads.heads,
    purpose: purpose.purpose,
  };
}

// ---------------------------------------------------------------------------
// Permit requirements: answered from this static table rather than a lookup.
// The same fourteen codes PermitReadiness.messageFor carries on the client, so
// the chat and the reservation screen never disagree about why a permit is
// held up. No database round trip, no model call.
// ---------------------------------------------------------------------------

export const permitBlockerMessages: Record<string, string> = {
  not_confirmed: "Reservation approval is required.",
  full_payment_required: "Full payment must be verified.",
  requester_unit_required: "Office/College is required.",
  external_details_required: "External permit details are incomplete.",
  permit_items_required: "Permit item snapshots are missing.",
  unmapped_permit_item: "Permit setup is incomplete for this reservation.",
  schedule_required: "An active reservation schedule is required.",
  external_row_limit:
    "The selected items exceed the official eight-row table.",
  duplicate_external_row:
    "Multiple items map ambiguously to one official row.",
  item_quantity_required: "Tables/chairs quantity is required.",
  requester_signature_required: "Requester signature is required.",
  internal_approver_signature_required:
    "Internal approving signature is required.",
  external_recommender_signature_required:
    "Business Coordinator signature is required.",
  external_authorized_signature_required:
    "President/Authorized Official signature is required.",
};

export function permitBlockerMessage(code: string): string {
  return permitBlockerMessages[code] ??
    "Official permit processing is incomplete.";
}

// ---------------------------------------------------------------------------
// Response cache
//
// Only answers built purely from policy may be cached. An answer that touched
// any user-scoped tool is about one person's records, and serving it to
// somebody else who happened to phrase the question the same way would be a
// data leak dressed up as an optimisation. The allowlist below is the guard,
// and the audience is part of the key because policy itself differs by lane.
// ---------------------------------------------------------------------------

const cacheableTools = new Set<string>([
  "get_policy_or_faq",
  "get_permit_requirements",
]);

export function isCacheable(toolsUsed: readonly string[]): boolean {
  // No tools at all means the model answered from the prompt, which is not
  // grounded in anything and must not be cached either.
  if (toolsUsed.length === 0) return false;
  return toolsUsed.every((tool) => cacheableTools.has(tool));
}

/** Normalize a question so trivial rephrasings share a cache entry. */
export function normalizeQuestion(message: string): string {
  return message
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export async function cacheKeyFor(
  message: string,
  audience: string,
  knowledgeVersion: string,
): Promise<string> {
  const source = `${normalizeQuestion(message)}|${audience}|${knowledgeVersion}`;
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(source),
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

// ---------------------------------------------------------------------------
// Output channel parsing
// ---------------------------------------------------------------------------

/**
 * Parse the model's out-of-band channels out of the raw reply.
 *
 * Lives here, with the other pure logic, so it can be tested at all. It was
 * private to index.ts -- a module that reads env and starts a server on
 * import -- which is most of the reason the fenced block leaked to users for
 * as long as it did: the one function that knew the block existed could not
 * be reached without standing up a whole request.
 */
export function extractChannels(reply: string): {
  slotFill: unknown;
  proposal: unknown;
  summary: string | null;
} {
  const out: {
    slotFill: unknown;
    proposal: unknown;
    summary: string | null;
  } = {
    slotFill: null,
    proposal: null,
    summary: null,
  };
  const blocks = reply.match(/```json\s*([\s\S]*?)```/g) ?? [];
  for (const block of blocks) {
    const inner = block.replace(/```json\s*/, "").replace(/```$/, "");
    let parsed: unknown;
    try {
      parsed = JSON.parse(inner);
    } catch (_) {
      continue;
    }
    if (!parsed || typeof parsed !== "object") continue;
    const record = parsed as Record<string, unknown>;
    if (record.fill_booking_slot) {
      try {
        out.slotFill = validateSlotFill(record.fill_booking_slot);
      } catch (_) { /* dropped */ }
    }
    if (record.proposal) {
      try {
        out.proposal = validateProposal(record.proposal);
      } catch (_) { /* dropped */ }
    }
    // The rolling summary rides the channel block rather than a tag of its
    // own, so it costs no extra model call and needs no second parser or
    // second thing to remember to strip out of the answer.
    if (typeof record.summary === "string") {
      const trimmed = record.summary.trim().slice(0, maxSummaryChars);
      if (trimmed) out.summary = trimmed;
    }
  }
  return out;
}
