// The assistant's cloud-model turn.
//
// This function is an escalation path, never the main one. SmartReserve's
// assistant answers most questions from rules in the Flutter client at no
// cost; a request only reaches here when the deterministic parser could not
// classify the message. If this function is disabled, unreachable, or failing,
// the app keeps working -- the client falls back to the same deterministic
// reply it would have given before this feature existed.
//
// Two Supabase clients, and the difference between them is the security model:
//
//   admin       service role. Validates the bearer token, writes telemetry and
//               rate-limit rows. Never passed to a tool handler.
//   userClient  anon key plus the caller's own JWT. Every tool read goes
//               through it, so row-level security decides what comes back.
//
// can_manage_facility() is deliberately broad and admin_lane() is null for
// non-admins, so the internal/external lane separation protecting reservation,
// payment and permit data lives only inside RLS. A service-role read would
// walk straight past it.

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  AssistantProviderError,
  cacheKeyFor,
  type ChatTurn,
  checkReply,
  extractChannels,
  estimateMessagesTokens,
  isCacheable,
  maxSummaryChars,
  maxToolCallsPerRound,
  maxToolRounds,
  parsePositiveInt,
  sanitizeErrorCode,
  summaryAfterTurns,
  tidyReply,
  validateToolCall,
} from "./contract.ts";
import { complete, type ProviderToolCall } from "./openai.ts";
import { buildContextBlock, buildMessages, buildSystemPrompt, toolDefinitions } from "./prompt.ts";
import { type RpcClient, runTool, type ToolContext } from "./tools.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// Off by default, exactly as the sentiment worker ships. Enabling it is a
// deliberate act that follows the privacy review, not a deployment side
// effect.
const enabled = (Deno.env.get("ASSISTANT_ENABLED") ?? "false")
  .toLowerCase() === "true";
const provider = (Deno.env.get("ASSISTANT_LLM_PROVIDER") ?? "openai")
  .toLowerCase();
const apiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
const model = Deno.env.get("ASSISTANT_MODEL") ?? "gpt-4o-mini";

const timeoutMs = parsePositiveInt(
  Deno.env.get("ASSISTANT_PROVIDER_TIMEOUT_MS"),
  15000,
  1000,
  30000,
);
const maxCompletionTokens = parsePositiveInt(
  Deno.env.get("ASSISTANT_MAX_COMPLETION_TOKENS"),
  300,
  64,
  1024,
);
const maxInputTokens = parsePositiveInt(
  Deno.env.get("ASSISTANT_MAX_INPUT_TOKENS"),
  3000,
  500,
  16000,
);
const rateLimitPerHour = parsePositiveInt(
  Deno.env.get("ASSISTANT_RATE_LIMIT_PER_HOUR"),
  30,
  1,
  500,
);
// Part of every cache key, so editing the knowledge base and bumping this
// invalidates every answer that quoted the old wording.
const knowledgeVersion = Deno.env.get("ASSISTANT_KB_VERSION") ?? "1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  // Kept in step with the headers Supabase's browser clients emit: a missing
  // one makes the browser discard a healthy response as a network error.
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-api-version, x-region",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Expose-Headers": "sb-request-id",
  "Vary": "Origin, Access-Control-Request-Headers",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });

// Real HTTP status codes with a stable envelope. The Flutter client's
// functions.invoke error handling reads far more cleanly against these than
// against an ok:false body returned as 200.
const failure = (
  code: string,
  error: string,
  requestId: string,
  status: number,
  extra: Record<string, unknown> = {},
) => json({ code, error, request_id: requestId, ...extra }, status);

function logEvent(event: Record<string, unknown>) {
  console.log(JSON.stringify({ component: "assistant-chat", ...event }));
}

Deno.serve(async (request) => {
  const requestId = crypto.randomUUID();
  const started = Date.now();

  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return failure("method_not_allowed", "POST required.", requestId, 405);
  }
  if (!supabaseUrl || !serviceRoleKey || !anonKey) {
    return failure(
      "configuration_error",
      "The assistant is not configured.",
      requestId,
      500,
    );
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 1. Identity. From the JWT only -- never the body, never the chat text.
  const authorization = request.headers.get("authorization") ?? "";
  const token = authorization.replace(/^Bearer\s+/i, "").trim();
  if (!token) {
    return failure("unauthorized", "Please sign in again.", requestId, 401);
  }
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  const user = authData?.user;
  if (authError || !user) {
    return failure("unauthorized", "Please sign in again.", requestId, 401);
  }

  // 2. Kill switch. Reported as a normal result, not an error: the client
  // treats it as "use the deterministic answer", which is not a failure.
  if (!enabled) {
    return json({ request_id: requestId, disabled: true, reply: null });
  }
  if (provider !== "openai") {
    return failure(
      "configuration_error",
      "The assistant is not configured.",
      requestId,
      500,
    );
  }

  let body: Record<string, unknown>;
  try {
    const parsed = await request.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("bad body");
    }
    body = parsed as Record<string, unknown>;
  } catch (_) {
    return failure(
      "invalid_request",
      "Send the message again.",
      requestId,
      400,
    );
  }

  const message = typeof body.message === "string" ? body.message.trim() : "";
  if (!message) {
    return failure("invalid_request", "Nothing to answer.", requestId, 400);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 3. Rate limit, before the provider call so an exhausted user costs nothing.
  const limit = await consumeRateLimit(admin, user.id, requestId);
  if (!limit.allowed) {
    // Logged, not just returned. outcome = 'rate_limited' is a legal value the
    // table allowed and nothing ever wrote, because this returned before
    // reaching any logging -- so the one signal that says "someone is hitting
    // the ceiling" was the only one invisible in telemetry.
    await logRequest(admin, {
      requestId,
      userId: user.id,
      conversationId: body.conversationId,
      route: "llm",
      toolsUsed: [],
      inputTokens: 0,
      outputTokens: 0,
      latencyMs: Date.now() - started,
      outcome: "rate_limited",
      rounds: 0,
    });
    return failure(
      "rate_limited",
      "You have asked a lot of questions in the last hour. Try again shortly.",
      requestId,
      429,
      { retry_after_seconds: limit.retryAfterSeconds },
    );
  }

  // 4. Session facts. Role and lane come from the database, not the request.
  const profile = await loadSessionFacts(userClient);

  // 4a. Cache. Only policy answers are ever stored, and the audience is part
  // of the key, so a hit can never be another person's records.
  const cacheKey = await cacheKeyFor(
    message,
    profile.pricingAudience,
    knowledgeVersion,
  );
  const cached = await readCache(admin, cacheKey, requestId);
  if (cached) {
    await logRequest(admin, {
      requestId,
      userId: user.id,
      conversationId: body.conversationId,
      route: "cache",
      toolsUsed: [],
      inputTokens: 0,
      outputTokens: 0,
      latencyMs: Date.now() - started,
      outcome: "answered",
      rounds: 0,
    });
    logEvent({ request_id: requestId, status: "cache_hit" });
    return json({
      request_id: requestId,
      reply: cached,
      tools_used: [],
      cached: true,
      usage: { input_tokens: 0, output_tokens: 0 },
    });
  }

  const history: ChatTurn[] = Array.isArray(body.history)
    ? (body.history as unknown[]).flatMap((turn) => {
      if (!turn || typeof turn !== "object") return [];
      const record = turn as Record<string, unknown>;
      const role = record.role === "assistant" ? "assistant" : "user";
      const content = typeof record.content === "string" ? record.content : "";
      return content ? [{ role, content } as ChatTurn] : [];
    })
    : [];

  const inBookingFlow = body.in_booking_flow === true;
  const turnCount = typeof body.turn_count === "number" &&
      Number.isFinite(body.turn_count)
    ? Math.max(0, Math.floor(body.turn_count))
    : history.length;
  const bookingDraft =
    body.booking_draft && typeof body.booking_draft === "object" &&
      !Array.isArray(body.booking_draft)
      ? body.booking_draft as Record<string, unknown>
      : null;

  const toolContext: ToolContext = {
    userId: user.id,
    lane: profile.lane,
    pricingAudience: profile.pricingAudience,
    isAdmin: profile.isAdmin,
    bookingDraft,
  };

  // 4b. Pre-retrieval. The knowledge base is fetched before the model runs,
  // not after it decides to ask for it.
  //
  // get_policy_or_faq stays registered for follow-ups, but relying on it alone
  // cost two full round trips for every policy question -- one to choose the
  // tool, one to answer from it -- and produced nothing at all when the model
  // chose not to call it. This is the single largest saving available: policy
  // is the most cacheable, most repeated class of question the assistant gets.
  const knowledge = await retrieveKnowledge(userClient, message, requestId);

  const messages = buildMessages({
    knowledge,
    system: buildSystemPrompt({
      lane: profile.lane,
      pricingAudience: profile.pricingAudience,
      isAdmin: profile.isAdmin,
      todayIso: manilaToday(),
      inBookingFlow,
      // Only once the conversation has outgrown the replayed window. The
      // client sends its running total; falling back to the history length
      // means a client that never sends one simply never asks for a summary,
      // which is the safe direction.
      wantsSummary: turnCount > summaryAfterTurns,
    }),
    summary: typeof body.summary === "string" ? body.summary : null,
    history,
    contextBlock: buildContextBlock(
      body.context && typeof body.context === "object" &&
        !Array.isArray(body.context)
        ? body.context as Record<string, unknown>
        : undefined,
    ),
    message,
  });

  // 5. Input budget. A request that would blow the cap is refused here rather
  // than truncated -- a half-sent conversation produces a confident wrong
  // answer, which is worse than falling back to rules.
  const estimated = estimateMessagesTokens(messages);
  if (estimated > maxInputTokens) {
    logEvent({
      request_id: requestId,
      status: "input_budget_exceeded",
      estimated_input_tokens: estimated,
    });
    return failure(
      "input_too_large",
      "That conversation is too long for me to follow. Start a new chat.",
      requestId,
      413,
    );
  }

  // 6. The bounded tool loop.
  const toolsUsed: string[] = [];
  const toolResultsJson: string[] = [];
  let inputTokens = 0;
  let outputTokens = 0;
  let reply = "";
  let rounds = 0;

  try {
    for (rounds = 0; rounds <= maxToolRounds; rounds++) {
      const result = await complete({
        apiKey,
        model,
        timeoutMs,
        maxCompletionTokens,
        messages,
        tools: toolDefinitions(),
      });
      inputTokens += result.usage.inputTokens;
      outputTokens += result.usage.outputTokens;

      if (result.toolCalls.length === 0 || rounds === maxToolRounds) {
        reply = result.content;
        break;
      }

      messages.push({
        role: "assistant",
        content: result.content || null,
        tool_calls: result.toolCalls,
      });

      for (const call of result.toolCalls.slice(0, maxToolCallsPerRound)) {
        const payload = await dispatch(call, userClient, toolContext);
        if (payload.name) toolsUsed.push(payload.name);
        toolResultsJson.push(payload.json);
        messages.push({
          role: "tool",
          tool_call_id: call.id,
          content: payload.json,
        });
      }
    }
  } catch (error) {
    const normalized = error instanceof AssistantProviderError
      ? error
      : new AssistantProviderError(sanitizeErrorCode(String(error)));
    logEvent({
      request_id: requestId,
      status: "provider_failed",
      error_code: normalized.code,
      duration_ms: Date.now() - started,
    });
    await logRequest(admin, {
      requestId,
      userId: user.id,
      conversationId: body.conversationId,
      route: "llm",
      toolsUsed,
      inputTokens,
      outputTokens,
      latencyMs: Date.now() - started,
      outcome: "error",
      errorCode: normalized.code,
      rounds,
      resolvedIntent: resolveIntent(inBookingFlow, toolsUsed),
    });
    return failure(
      normalized.code,
      providerMessage(normalized.code),
      requestId,
      normalized.code === "rate_limited" ? 429 : 503,
      normalized.retryAfterSeconds
        ? { retry_after_seconds: normalized.retryAfterSeconds }
        : {},
    );
  }

  // 7. The response contract. A fluent answer that is not grounded in this
  // turn's tool results is discarded, not shipped: the client then gives its
  // deterministic reply, which is always safe even when it is less graceful.
  const tidied = tidyReply(reply);
  const verdict = checkReply(tidied, toolResultsJson);
  if (!verdict.ok) {
    logEvent({
      request_id: requestId,
      status: "reply_rejected",
      error_code: verdict.code,
      detail: verdict.detail,
    });
    await logRequest(admin, {
      requestId,
      userId: user.id,
      conversationId: body.conversationId,
      route: "llm",
      toolsUsed,
      inputTokens,
      outputTokens,
      latencyMs: Date.now() - started,
      outcome: "fallback",
      errorCode: verdict.code,
      rounds,
      resolvedIntent: resolveIntent(inBookingFlow, toolsUsed),
    });
    return json({
      request_id: requestId,
      reply: null,
      fallback: true,
      code: verdict.code,
    });
  }

  // 8. Optional channels. Validated, never executed -- the client applies them
  // through the same validators a typed or tapped value goes through.
  const channels = extractChannels(reply);

  // Store only if nothing user-scoped was consulted. `isCacheable` is the
  // guard; getting it wrong would serve one person's balance to another.
  if (isCacheable(toolsUsed) && !channels.slotFill && !channels.proposal) {
    await writeCache(
      admin,
      cacheKey,
      tidied,
      profile.pricingAudience,
      requestId,
    );
  }

  // Persist the rolling summary, if the model produced one. Ownership is
  // re-checked in SQL against the verified user id: conversationId arrives in
  // the request body and is therefore the caller's claim, not a fact.
  if (channels.summary && typeof body.conversationId === "string") {
    await storeSummary(
      admin,
      user.id,
      body.conversationId,
      channels.summary,
      turnCount,
      requestId,
    );
  }

  await logRequest(admin, {
    requestId,
    userId: user.id,
    conversationId: body.conversationId,
    route: "llm",
    toolsUsed,
    inputTokens,
    outputTokens,
    latencyMs: Date.now() - started,
    outcome: "answered",
    rounds,
    resolvedIntent: resolveIntent(inBookingFlow, toolsUsed),
  });
  logEvent({
    request_id: requestId,
    status: "answered",
    tools: toolsUsed,
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    duration_ms: Date.now() - started,
  });

  return json({
    request_id: requestId,
    reply: tidied,
    tools_used: toolsUsed,
    slot_fill: channels.slotFill,
    proposal: channels.proposal,
    // Echoed so the client can send it back next turn without a read.
    summary: channels.summary,
    usage: {
      input_tokens: inputTokens,
      output_tokens: outputTokens,
    },
  });
});

async function dispatch(
  call: ProviderToolCall,
  client: RpcClient,
  context: ToolContext,
): Promise<{ name: string | null; json: string }> {
  try {
    const validated = validateToolCall(
      call.function.name,
      call.function.arguments,
    );
    if (validated.strippedArguments.length > 0) {
      // A model asking whose data to read is common and harmless: identity
      // comes from the JWT, so the argument is dropped and the call proceeds.
      logEvent({
        status: "identity_argument_stripped",
        tool: validated.name,
        arguments: validated.strippedArguments,
      });
    }
    const outcome = await runTool(
      client,
      validated.name,
      validated.args,
      context,
    );
    return {
      name: validated.name,
      json: JSON.stringify(outcome.result).slice(0, 4000),
    };
  } catch (error) {
    const code = error instanceof AssistantProviderError
      ? error.code
      : "invalid_tool_call";
    return {
      name: null,
      json: JSON.stringify({
        error: code,
        note: "That request was not valid. Ask the user instead of retrying.",
      }),
    };
  }
}

/**
 * Pull the optional JSON channels out of the reply.
 *
 * Anything malformed is dropped silently: a missing proposal costs the user a
 * tap, whereas a half-validated one would cost correctness.
 */

function providerMessage(code: string): string {
  switch (code) {
    case "rate_limited":
      return "The assistant is busy right now. Try again shortly.";
    case "provider_timeout":
      return "That took too long. Try asking again.";
    case "configuration_error":
    case "provider_auth_error":
      return "The assistant is unavailable right now.";
    default:
      return "I could not reach the assistant service just now.";
  }
}

async function loadSessionFacts(
  client: RpcClient,
): Promise<{ lane: string; pricingAudience: string; isAdmin: boolean }> {
  try {
    const { data } = await client.rpc("get_my_session_profile");
    const record = data && typeof data === "object"
      ? data as Record<string, unknown>
      : {};
    const role = `${record.role ?? "user"}`;
    const verified = `${record.verification_status ?? ""}` === "verified";
    const accessType = `${record.account_access_type ?? ""}`;
    const lane = verified && accessType === "organization_representative"
      ? "internal"
      : "external";
    const claim = `${record.campus_claim ?? "none"}`;
    return {
      lane,
      pricingAudience: lane === "internal" && claim !== "none" ? claim : "guest",
      isAdmin: role === "internal_admin" || role === "external_admin",
    };
  } catch (_) {
    // A failed profile read must not leak a more privileged default.
    return { lane: "external", pricingAudience: "guest", isAdmin: false };
  }
}

/**
 * Policy text for this question, fetched before the model runs.
 *
 * Two chunks, not three: the retrieval is a hint, and the model still has
 * get_policy_or_faq if the question turns out to be narrower than the search
 * guessed. Runs on the caller-scoped client, so the knowledge base's own
 * audience policy decides which chunks are visible -- an external renter must
 * not be told the internal rules just because a keyword matched.
 *
 * A failure here is not an error: the assistant simply answers without the
 * quotation, exactly as it did before pre-retrieval existed.
 */
async function retrieveKnowledge(
  client: RpcClient,
  message: string,
  requestId: string,
): Promise<string | null> {
  try {
    const { data, error } = await client.rpc("assistant_knowledge_search", {
      p_query: message,
      p_limit: 2,
    });
    if (error) throw error;
    const record = data && typeof data === "object"
      ? data as Record<string, unknown>
      : {};
    const chunks = Array.isArray(record.chunks) ? record.chunks : [];
    if (chunks.length === 0) return null;

    const lines: string[] = [];
    for (const chunk of chunks) {
      if (!chunk || typeof chunk !== "object") continue;
      const row = chunk as Record<string, unknown>;
      const answer = typeof row.answer === "string" ? row.answer : "";
      if (answer) lines.push(`- ${answer}`);
    }
    return lines.length > 0 ? lines.join("\n") : null;
  } catch (error) {
    logEvent({
      request_id: requestId,
      status: "knowledge_lookup_failed",
      error_code: sanitizeErrorCode(String(error)),
    });
    return null;
  }
}

/**
 * Save the conversation's rolling summary.
 *
 * Best-effort: losing it costs a slightly less contextual next turn, which is
 * not worth failing an answer the user already has.
 */
async function storeSummary(
  admin: RpcClient,
  userId: string,
  conversationId: string,
  summary: string,
  turnCount: number,
  requestId: string,
): Promise<void> {
  try {
    const { error } = await admin.rpc(
      "assistant_update_conversation_summary",
      {
        p_owner_id: userId,
        p_conversation_id: conversationId,
        p_summary: summary.slice(0, maxSummaryChars),
        p_turn_count: turnCount,
      },
    );
    if (error) throw error;
  } catch (error) {
    logEvent({
      request_id: requestId,
      status: "summary_write_failed",
      error_code: sanitizeErrorCode(String(error)),
    });
  }
}

async function consumeRateLimit(
  admin: RpcClient,
  userId: string,
  requestId: string,
): Promise<{ allowed: boolean; retryAfterSeconds?: number }> {
  try {
    const { data, error } = await admin.rpc("assistant_consume_rate_limit", {
      p_user_id: userId,
      p_window_seconds: 3600,
      p_max: rateLimitPerHour,
    });
    if (error) throw error;
    const record = data && typeof data === "object"
      ? data as Record<string, unknown>
      : {};
    return {
      allowed: record.allowed !== false,
      retryAfterSeconds: typeof record.retry_after_seconds === "number"
        ? record.retry_after_seconds
        : undefined,
    };
  } catch (error) {
    // Fail open, and say so in the log. A broken counter must not take the
    // assistant down; the provider's own rate limit is still a backstop.
    logEvent({
      request_id: requestId,
      status: "rate_limit_unavailable",
      error_code: sanitizeErrorCode(String(error)),
    });
    return { allowed: true };
  }
}

/**
 * Read a cached policy answer. A cache miss and a broken cache are the same
 * thing to the caller: ask the model.
 */
async function readCache(
  admin: RpcClient,
  cacheKey: string,
  requestId: string,
): Promise<string | null> {
  try {
    const { data, error } = await admin.rpc("assistant_cache_get", {
      p_cache_key: cacheKey,
    });
    if (error) throw error;
    const record = data && typeof data === "object"
      ? data as Record<string, unknown>
      : {};
    return record.hit === true && typeof record.answer === "string"
      ? record.answer
      : null;
  } catch (error) {
    logEvent({
      request_id: requestId,
      status: "cache_read_failed",
      error_code: sanitizeErrorCode(String(error)),
    });
    return null;
  }
}

async function writeCache(
  admin: RpcClient,
  cacheKey: string,
  answer: string,
  audience: string,
  requestId: string,
): Promise<void> {
  try {
    await admin.rpc("assistant_cache_put", {
      p_cache_key: cacheKey,
      p_answer: answer,
      p_audience: audience,
      p_ttl_seconds: 604800,
    });
  } catch (error) {
    // A failed write costs one future cache hit, nothing more.
    logEvent({
      request_id: requestId,
      status: "cache_write_failed",
      error_code: sanitizeErrorCode(String(error)),
    });
  }
}

type RequestLog = {
  requestId: string;
  userId: string;
  conversationId: unknown;
  route: string;
  toolsUsed: string[];
  inputTokens: number;
  outputTokens: number;
  latencyMs: number;
  outcome: string;
  errorCode?: string;
  rounds: number;
  /**
   * What the turn turned out to be about.
   *
   * The column and the RPC parameter both existed and nothing ever sent it,
   * which quietly defeated the point of the table: rows with
   * outcome = 'fallback' are the backlog of phrasings that should become free
   * deterministic rules, and without an intent there is nothing to group them
   * by. 'unknown' is itself the most useful value -- it is the queue.
   */
  resolvedIntent?: string | null;
};

async function logRequest(
  admin: RpcClient,
  entry: RequestLog,
): Promise<void> {
  try {
    await admin.rpc("assistant_log_llm_request", {
      p_request_id: entry.requestId,
      p_user_id: entry.userId,
      p_conversation_id: typeof entry.conversationId === "string"
        ? entry.conversationId
        : null,
      p_route: entry.route,
      p_tools_used: entry.toolsUsed,
      p_provider: provider,
      p_model: model,
      p_input_tokens: entry.inputTokens,
      p_output_tokens: entry.outputTokens,
      p_latency_ms: entry.latencyMs,
      p_tool_rounds: entry.rounds,
      p_outcome: entry.outcome,
      p_error_code: entry.errorCode ?? null,
      p_resolved_intent: entry.resolvedIntent ?? null,
    });
  } catch (error) {
    // Telemetry must never fail a user's answer.
    logEvent({
      request_id: entry.requestId,
      status: "telemetry_write_failed",
      error_code: sanitizeErrorCode(String(error)),
    });
  }
}

/**
 * What the turn was about, for the telemetry backlog.
 *
 * Derived rather than asked for: the tools the model actually reached for say
 * more about the real subject than the phrasing that could not be classified.
 * Rows that answer with no tool at all are the interesting ones -- they are
 * either chat or a gap in the rule layer.
 */
function resolveIntent(
  inBookingFlow: boolean,
  toolsUsed: readonly string[],
): string {
  if (inBookingFlow) return "booking_slot";
  if (toolsUsed.length === 0) return "unknown";
  const first = toolsUsed[0];
  if (first === "get_policy_or_faq" || first === "get_permit_requirements") {
    return "policy";
  }
  if (first.startsWith("get_payment")) return "payment";
  if (first.startsWith("get_permit")) return "permit";
  if (first.includes("availability") || first === "get_available_facilities") {
    return "availability";
  }
  if (first.includes("reservation")) return "reservations";
  if (first.includes("facilit")) return "facilities";
  return first;
}

/** Today in Asia/Manila, matching the campus clock the whole app uses. */
function manilaToday(): string {
  const now = new Date();
  const manila = new Date(now.getTime() + 8 * 60 * 60 * 1000);
  return manila.toISOString().slice(0, 10);
}
