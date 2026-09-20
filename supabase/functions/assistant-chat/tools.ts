// The tool registry: the complete set of things the model can cause to happen.
//
// Every handler receives the caller-scoped Supabase client -- built with the
// anon key and the user's own JWT -- so row-level security decides what comes
// back. The service-role client is never passed in here. That is the whole
// security model in one sentence: a prompt injection can change what is asked
// for, but not who is asking.
//
// Every handler is a read. There is no write tool, no SQL tool, and no
// query-builder tool; the only database surface is the fixed list of
// projection RPCs below.

import {
  facilityCategories,
  permitBlockerMessage,
  redactForProvider,
  type ToolName,
} from "./contract.ts";

/**
 * Only the surface this layer actually uses.
 *
 * These RPC names are not in the project's generated types, so the concrete
 * RpcClient generics narrow `rpc` params to `undefined`. Declaring what we
 * depend on is both honest and stable: it also makes it impossible for a tool
 * handler to reach for `.from()` and bypass a projection.
 */
export type RpcClient = {
  rpc(
    name: string,
    params?: Record<string, unknown>,
  ): PromiseLike<{ data: unknown; error: { code?: string; message?: string } | null }>;
};

export type ToolContext = {
  /** Verified from the JWT, never from the request body or chat text. */
  userId: string;
  lane: string;
  pricingAudience: string;
  isAdmin: boolean;
  /** The client's in-progress booking draft, passed through untouched. */
  bookingDraft?: Record<string, unknown> | null;
};

export type ToolHandler = (
  client: RpcClient,
  args: Record<string, unknown>,
  context: ToolContext,
) => Promise<unknown>;

async function rpc(
  client: RpcClient,
  name: string,
  params: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await client.rpc(name, params);
  if (error) {
    // Map to a stable code. Raw Postgres text must never reach the model, let
    // alone a user: it would be paraphrased into an answer.
    if (error.code === "42501") {
      throw new ToolAccessError("not_found_or_not_yours");
    }
    throw new ToolAccessError("lookup_failed");
  }
  return data;
}

export class ToolAccessError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "ToolAccessError";
  }
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function pick(
  source: Record<string, unknown>,
  keys: readonly string[],
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const key of keys) {
    if (source[key] !== undefined && source[key] !== null) out[key] = source[key];
  }
  return out;
}

/** Peso string from centavos, matching the client's pesoFromCentavos exactly. */
export function pesoFromCentavos(centavos: number): string {
  const amount = centavos / 100;
  const whole = amount === Math.round(amount);
  return `₱${whole ? amount.toFixed(0) : amount.toFixed(2)}`;
}

/**
 * Money is formatted here, once, before it is ever shown to the model.
 *
 * The model is told to repeat amounts verbatim, which only works if it is
 * handed the finished string. Sending raw centavos would invite arithmetic,
 * which is exactly what the rule layer exists to prevent.
 */
function withFormattedMoney(
  row: Record<string, unknown>,
): Record<string, unknown> {
  const out = { ...row };
  for (const [key, value] of Object.entries(row)) {
    if (key.endsWith("_centavos") && typeof value === "number") {
      out[key.replace(/_centavos$/, "")] = pesoFromCentavos(value);
      delete out[key];
    }
  }
  return out;
}

const manilaDateTime = new Intl.DateTimeFormat("en-PH", {
  timeZone: "Asia/Manila",
  weekday: "short",
  day: "2-digit",
  month: "short",
  year: "numeric",
  hour: "numeric",
  minute: "2-digit",
  hour12: true,
});

/** "Fri, 25 Sep 2026, 2:00 PM" in Asia/Manila, or null if unparseable. */
export function manilaTimestamp(value: unknown): string | null {
  if (typeof value !== "string" || !value) return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  return manilaDateTime.format(parsed).replace(/,\s*$/, "");
}

/**
 * Dates are formatted here, once, for the same reason money is.
 *
 * The system prompt tells the model that dates arrive already formatted and
 * must be repeated exactly. That was untrue: every timestamp reached it as a
 * raw UTC ISO string, so the only way to answer "when is my payment due" was
 * to convert and phrase it -- inventing the very thing the prompt forbade,
 * and in the wrong timezone. Now the string it repeats is the string the app
 * shows.
 *
 * The ISO original is kept under `<field>_iso` only where the value can feed
 * a slot fill; everywhere else it is dropped, because two spellings of one
 * timestamp is just tokens.
 */
function withFormattedDates(
  row: Record<string, unknown>,
  keepIso: readonly string[] = [],
): Record<string, unknown> {
  const out = { ...row };
  for (const [key, value] of Object.entries(row)) {
    if (!/(?:_at|starts|ends)$/.test(key)) continue;
    const formatted = manilaTimestamp(value);
    if (formatted === null) continue;
    if (keepIso.includes(key)) out[`${key}_iso`] = value;
    out[key] = formatted;
  }
  return out;
}

const reservationListFields = [
  "id",
  "facility_name",
  "starts_at",
  "ends_at",
  "lifecycle_status",
  "outstanding_amount_centavos",
] as const;

async function reservationsFor(
  client: RpcClient,
  scope: "active" | "upcoming",
): Promise<unknown> {
  const data = asRecord(await rpc(client, "assistant_my_reservations", {
    p_scope: scope,
    p_limit: 10,
  }));
  const rows = Array.isArray(data.reservations) ? data.reservations : [];
  return {
    scope,
    reservations: rows.map((row) =>
      withFormattedDates(
        withFormattedMoney(pick(asRecord(row), reservationListFields)),
      )
    ),
  };
}

async function detailFor(
  client: RpcClient,
  reservationId: unknown,
): Promise<Record<string, unknown>> {
  return asRecord(
    await rpc(client, "assistant_reservation_detail", {
      p_request_id: reservationId,
    }),
  );
}

export const toolHandlers: Record<ToolName, ToolHandler> = {
  get_my_reservations: (client) => reservationsFor(client, "active"),

  get_upcoming_reservations: (client) => reservationsFor(client, "upcoming"),

  get_reservation_details: async (client, args) => {
    const detail = await detailFor(client, args.reservation_id);
    return withFormattedDates(
      withFormattedMoney(
        pick(detail, [
          "id",
          "facility_name",
          "facility_building",
          "starts_at",
          "ends_at",
          "lifecycle_status",
          "headcount",
          "purpose",
          "total_amount_centavos",
          "outstanding_amount_centavos",
          "payment_due_at",
          "balance_due_at",
          "can_cancel",
          "permit_downloadable",
          "permit_number",
        ]),
      ),
      // The schedule is the one field a booking proposal is built from, so the
      // machine-readable spelling survives alongside the human one.
      ["starts_at", "ends_at"],
    );
  },

  get_reservation_status: async (client, args) => {
    const detail = await detailFor(client, args.reservation_id);
    return withFormattedDates(pick(detail, [
      "id",
      "facility_name",
      "starts_at",
      "lifecycle_status",
      "can_cancel",
    ]));
  },

  get_payment_balance: async (client, args) => {
    const detail = await detailFor(client, args.reservation_id);
    const total = Number(detail.total_amount_centavos ?? 0);
    const outstanding = Number(detail.outstanding_amount_centavos ?? 0);
    return {
      id: detail.id,
      facility_name: detail.facility_name,
      total: pesoFromCentavos(total),
      outstanding: pesoFromCentavos(outstanding),
      required_down_payment: pesoFromCentavos(
        Number(detail.required_down_payment_centavos ?? 0),
      ),
      exempt: detail.payment_exemption !== "none",
      settled: outstanding === 0,
    };
  },

  get_payment_status: async (client, args) => {
    const detail = await detailFor(client, args.reservation_id);
    const total = Number(detail.total_amount_centavos ?? 0);
    const verified = Number(detail.verified_amount_centavos ?? 0);
    const outstanding = Number(detail.outstanding_amount_centavos ?? 0);
    // The same precedence the client's aggregatePaymentStatus applies, so chat
    // and screen never disagree about what state a payment is in.
    const status = total === 0
      ? "not_required"
      : verified >= total
      ? "fully_paid"
      : verified > 0
      ? "partially_paid"
      : "unpaid";
    return {
      id: detail.id,
      facility_name: detail.facility_name,
      payment_status: status,
      outstanding: pesoFromCentavos(outstanding),
    };
  },

  get_payment_deadline: async (client, args) => {
    const detail = await detailFor(client, args.reservation_id);
    return withFormattedDates(pick(detail, [
      "id",
      "facility_name",
      "payment_due_at",
      "balance_due_at",
    ]));
  },

  get_permit_status: async (client, args) => {
    const detail = await detailFor(client, args.reservation_id);
    const readiness = asRecord(
      await rpc(client, "get_reservation_permit_readiness", {
        p_request_id: args.reservation_id,
      }),
    );
    const blockers = Array.isArray(readiness.blockers)
      ? readiness.blockers.map((code) => `${code}`)
      : [];
    return {
      id: detail.id,
      facility_name: detail.facility_name,
      // Generated is not the same as downloadable: the storage policy also
      // requires an administrator to have released it.
      downloadable: detail.permit_downloadable === true,
      ready: readiness.ready === true,
      template_kind: readiness.template_kind,
      blockers: blockers.map((code) => permitBlockerMessage(code)),
    };
  },

  get_permit_requirements: (_client, args) => {
    const kind = args.template_kind === "internal" ? "internal" : "external";
    const shared = [
      "The reservation must be approved.",
      "Any required payment must be verified.",
      "An administrator must map the official form items.",
      "Every signature slot, including yours, must be filled.",
    ];
    return Promise.resolve({
      template_kind: kind,
      requirements: kind === "internal"
        ? [...shared, "Your Office or College is required."]
        : [
          ...shared,
          "Company or organization, complete address, contact numbers and admission fee are required.",
          "The official external form has only eight item rows.",
        ],
    });
  },

  // Free windows, not busy ones.
  //
  // This used to return occupied windows on the reasoning that the client's
  // slot engine subtracts them. True for the client -- but the model reads
  // this result too, and nothing stopped it doing the subtraction itself and
  // announcing a time. assistant_facility_free_slots runs the same rules as
  // that slot engine, in the database, so the answer is a list to repeat
  // rather than a calculation to attempt.
  check_facility_availability: async (client, args) => {
    const payload = asRecord(
      await rpc(client, "assistant_facility_free_slots", {
        p_facility_id: args.facility_id,
        p_day: args.day,
        p_duration_hours: typeof args.duration_hours === "number"
          ? args.duration_hours
          : 1,
        p_limit: 6,
        p_from_hour: typeof args.from_hour === "number" ? args.from_hour : null,
        p_to_hour: typeof args.to_hour === "number" ? args.to_hour : null,
      }),
    );
    return pick(payload, [
      "facility_name",
      "day",
      "duration_hours",
      "open_time",
      "close_time",
      "bookable_for_me",
      "booking_block_reason",
      "unavailable_reason",
      "free_slots",
    ]);
  },

  // "What is free on Friday afternoon?"
  //
  // Not expressible as recommend_facilities + one availability call per
  // candidate: that exceeds the two-round, three-call ceiling as soon as
  // there are more than three rooms to consider.
  get_available_facilities: async (client, args) => {
    const payload = asRecord(
      await rpc(client, "assistant_available_facilities", {
        p_day: args.day,
        p_start_hour: typeof args.from_hour === "number" ? args.from_hour : null,
        p_end_hour: typeof args.to_hour === "number" ? args.to_hour : null,
        p_duration_hours: typeof args.duration_hours === "number"
          ? args.duration_hours
          : 1,
        p_min_capacity: typeof args.min_capacity === "number"
          ? args.min_capacity
          : null,
        p_category: typeof args.category === "string" ? args.category : null,
        // The RPC's own ceiling, asked for deliberately: it stops scanning
        // the moment it has p_limit rows, so a smaller limit would make
        // "there are no others" unknowable.
        p_limit: 10,
      }),
    );
    const all = Array.isArray(payload.facilities) ? payload.facilities : [];
    return {
      ...pick(payload, ["day", "duration_hours", "requested_window"]),
      facilities: all.slice(0, 5),
      // A count, not a total: assistant_available_facilities stops looking
      // once it has enough, so the true number of free facilities is not
      // knowable from here. This flag is, and it is all the model needs to
      // avoid implying the five below are everything.
      more_beyond_these: all.length > 5,
    };
  },

  get_facility_details: async (client, args) => {
    const facility = asRecord(
      await rpc(client, "assistant_facility_summary", {
        p_facility_id: args.facility_id,
      }),
    );
    const amenities = Array.isArray(facility.amenities)
      ? facility.amenities.map((item) => asRecord(item).name).filter(Boolean)
      : [];
    return {
      ...pick(facility, [
        "id",
        "name",
        "building",
        "category",
        "capacity",
        "status",
        "open_time",
        "close_time",
        "max_duration_minutes",
        "advance_booking_days",
        "bookable_for_me",
        "booking_block_reason",
      ]),
      amenities,
    };
  },

  get_equipment_availability: async (client, args) => {
    const day = typeof args.day === "string" ? args.day : null;
    const from = day ? new Date(`${day}T00:00:00+08:00`) : new Date();
    const to = new Date(from.getTime() + 24 * 60 * 60 * 1000);
    const result = asRecord(
      await rpc(client, "assistant_equipment_availability", {
        p_facility_id: args.facility_id,
        p_from: from.toISOString(),
        p_to: to.toISOString(),
      }),
    );
    const items = Array.isArray(result.items) ? result.items : [];
    return {
      // Stated explicitly so the model cannot imagine a count it was never
      // given: SmartReserve tracks no stock anywhere.
      tracks_stock_levels: false,
      items: items.map((item) => {
        const row = asRecord(item);
        return {
          name: row.name,
          price: pesoFromCentavos(Number(row.price_centavos ?? 0)),
          already_requested_at_that_time: row.requested_elsewhere === true,
        };
      }),
    };
  },

  get_announcements: async (client) => {
    const result = asRecord(
      await rpc(client, "assistant_my_announcements", { p_limit: 5 }),
    );
    const notices = Array.isArray(result.notices) ? result.notices : [];
    const advisories = Array.isArray(result.facility_advisories)
      ? result.facility_advisories
      : [];
    return {
      notices: notices.map((notice) =>
        pick(asRecord(notice), ["title", "body", "unread"])
      ),
      facility_advisories: advisories.map((advisory) =>
        pick(asRecord(advisory), ["facility_name", "status"])
      ),
    };
  },

  get_policy_or_faq: async (client, args) => {
    const result = asRecord(
      await rpc(client, "assistant_knowledge_search", {
        p_query: `${args.query ?? ""}`.slice(0, 300),
        p_limit: 3,
      }),
    );
    const chunks = Array.isArray(result.chunks) ? result.chunks : [];
    return {
      chunks: chunks.map((chunk) => pick(asRecord(chunk), ["slug", "answer"])),
    };
  },

  recommend_facilities: async (client, args) => {
    const result = asRecord(
      await rpc(client, "assistant_recommend_facilities", {
        p_min_capacity: typeof args.min_capacity === "number"
          ? Math.round(args.min_capacity)
          : null,
        p_category: typeof args.category === "string" ? args.category : null,
        p_limit: 20,
      }),
    );
    const facilities = Array.isArray(result.facilities) ? result.facilities : [];
    const wanted = Array.isArray(args.amenities)
      ? (args.amenities as string[]).map((a) => a.toLowerCase())
      : [];

    // The database filters to what this caller may actually book; the client's
    // ranker decides the order. Only the top few are returned so the prompt
    // never carries a catalogue.
    const annotated = facilities.map((entry) => {
      const row = asRecord(entry);
      const owned = Array.isArray(row.amenities)
        ? (row.amenities as unknown[]).map((a) => `${a}`)
        : [];
      const ownedLower = owned.map((a) => a.toLowerCase());
      return {
        id: row.id,
        name: row.name,
        building: row.building,
        category: row.category,
        capacity: row.capacity,
        amenities: owned,
        missing_amenities: wanted.filter((a) => !ownedLower.includes(a)),
      };
    });
    return {
      facilities: annotated.slice(0, 5),
      // The five rows above are a page; this is how many matched. Saying
      // "three fit" versus "three of eleven" is the difference between an
      // answer and a misleading one. assistant_recommend_facilities is asked
      // for 20 and caps there, which covers the whole catalogue comfortably
      // -- if it ever does not, this reads as a floor, never an overstatement.
      total_matching: annotated.length,
      // The complete vocabulary. "No facility here is a pickleball court" is
      // a claim about what does not exist, and the prompt forbids answering
      // from anything but this turn's tool results -- so the list of what
      // could exist has to arrive as a tool result too, not be recalled.
      catalogue_categories: facilityCategories,
    };
  },

  get_booking_draft_state: (_client, _args, context) => {
    // Supplied by the client rather than read from the database: a draft is
    // not persisted until it is submitted, so the client is its only source.
    return Promise.resolve(
      context.bookingDraft ?? { stage: "idle", missing_slot: null },
    );
  },
};

/**
 * Run one validated tool call and return a compact, redacted result.
 *
 * Errors are caught and returned as data so the model can respond gracefully
 * ("I could not check that") instead of the whole turn failing.
 */
export async function runTool(
  client: RpcClient,
  name: ToolName,
  args: Record<string, unknown>,
  context: ToolContext,
): Promise<{ ok: boolean; result: unknown; errorCode?: string }> {
  try {
    const raw = await toolHandlers[name](client, args, context);
    return { ok: true, result: redactForProvider(raw) };
  } catch (error) {
    const code = error instanceof ToolAccessError ? error.code : "lookup_failed";
    return {
      ok: false,
      errorCode: code,
      result: {
        error: code,
        note: code === "not_found_or_not_yours"
          ? "No such record for this user. Say you found nothing."
          : "This could not be checked right now. Say so plainly.",
      },
    };
  }
}
