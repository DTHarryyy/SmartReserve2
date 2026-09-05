import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  parsePositiveInt,
  sanitizeErrorCode,
  SentimentProviderError,
  type SentimentResult,
} from "./contract.ts";
import { analyzeWithGroq } from "./groq.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const workerKey = Deno.env.get("SENTIMENT_WORKER_KEY") ?? "";
const provider = (Deno.env.get("SENTIMENT_PROVIDER") ?? "groq").toLowerCase();
const model = Deno.env.get("SENTIMENT_MODEL") ?? "openai/gpt-oss-20b";
const groqApiKey = Deno.env.get("GROQ_API_KEY") ?? "";
const enabled = (Deno.env.get("SENTIMENT_ENABLED") ?? "false")
  .toLowerCase() === "true";
const version = parsePositiveInt(
  Deno.env.get("SENTIMENT_ANALYSIS_VERSION"),
  1,
  1,
  100,
);
const batchSize = parsePositiveInt(
  Deno.env.get("SENTIMENT_BATCH_SIZE"),
  5,
  1,
  25,
);
const timeoutMs = parsePositiveInt(
  Deno.env.get("SENTIMENT_PROVIDER_TIMEOUT_MS"),
  12000,
  1000,
  30000,
);
const maxCompletionTokens = parsePositiveInt(
  Deno.env.get("SENTIMENT_MAX_COMPLETION_TOKENS"),
  256,
  64,
  512,
);
const maxAttempts = parsePositiveInt(
  Deno.env.get("SENTIMENT_MAX_ATTEMPTS"),
  3,
  1,
  10,
);
const leaseSeconds = parsePositiveInt(
  Deno.env.get("SENTIMENT_LEASE_SECONDS"),
  120,
  30,
  600,
);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-smartreserve-worker-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type ClaimRow = {
  id: string;
  feedback_id: string;
  analysis_version: number;
  attempt_count: number;
  comment: string;
};

type SupabaseRpc = ReturnType<typeof createClient>;

const json = (body: unknown, status = 200) =>
  Response.json(body, {
    status,
    headers: { ...corsHeaders, "Cache-Control": "no-store" },
  });

Deno.serve(async (request) => {
  const requestId = crypto.randomUUID();

  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json(
      { code: "method_not_allowed", error: "Method not allowed", request_id: requestId },
      405,
    );
  }

  if (!workerKey || request.headers.get("x-smartreserve-worker-key") !== workerKey) {
    return json(
      { code: "unauthorized", error: "Unauthorized", request_id: requestId },
      401,
    );
  }

  if (!enabled) {
    return json({ request_id: requestId, disabled: true, claimed: 0, processed: 0 });
  }

  if (!supabaseUrl || !serviceRoleKey) {
    return json(
      { code: "configuration_error", error: "Sentiment worker is not configured.", request_id: requestId },
      500,
    );
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  let jobs: ClaimRow[];
  try {
    jobs = await claimJobs(admin, requestId);
  } catch (error) {
    return json(
      {
        code: sanitizeErrorCode(error instanceof Error ? error.message : error),
        error: "Could not claim sentiment work.",
        request_id: requestId,
      },
      500,
    );
  }
  let completed = 0;
  let failed = 0;
  let retried = 0;

  for (const job of jobs) {
    const started = Date.now();
    try {
      const result = await analyze(job.comment);
      await completeJob(admin, job, result);
      completed += 1;
      logEvent({
        request_id: requestId,
        analysis_id: job.id,
        feedback_id: job.feedback_id,
        status: "completed",
        provider,
        model,
        attempt: job.attempt_count,
        duration_ms: Date.now() - started,
      });
    } catch (error) {
      const providerError = normalizeError(error);
      const terminalMax = providerError.terminal ? 1 : maxAttempts;
      await failJob(admin, job, providerError, terminalMax);
      if (job.attempt_count >= terminalMax) {
        failed += 1;
      } else {
        retried += 1;
      }
      logEvent({
        request_id: requestId,
        analysis_id: job.id,
        feedback_id: job.feedback_id,
        status: job.attempt_count >= terminalMax ? "failed" : "retry_scheduled",
        provider,
        model,
        attempt: job.attempt_count,
        duration_ms: Date.now() - started,
        error_code: providerError.code,
      });
    }
  }

  return json({
    request_id: requestId,
    claimed: jobs.length,
    processed: completed + failed + retried,
    completed,
    failed,
    retried,
  });
});

async function claimJobs(admin: SupabaseRpc, requestId: string): Promise<ClaimRow[]> {
  const { data, error } = await admin.rpc("feedback_sentiment_claim", {
    p_limit: batchSize,
    p_version: version,
    p_lease_seconds: leaseSeconds,
    p_max_attempts: maxAttempts,
  });
  if (error) {
    logEvent({
      request_id: requestId,
      status: "claim_failed",
      error_code: sanitizeErrorCode(error.code || error.message),
    });
    throw error;
  }
  const rows = isRecord(data) && Array.isArray(data.rows) ? data.rows : [];
  return rows
    .filter(isRecord)
    .map((row) => ({
      id: String(row.id),
      feedback_id: String(row.feedback_id),
      analysis_version: Number(row.analysis_version) || version,
      attempt_count: Number(row.attempt_count) || 1,
      comment: typeof row.comment === "string" ? row.comment : "",
    }))
    .filter((row) => row.id && row.feedback_id && row.comment.trim().length > 0);
}

async function analyze(text: string): Promise<SentimentResult> {
  if (provider !== "groq") {
    throw new SentimentProviderError(
      "unsupported_provider",
      "Unsupported sentiment provider.",
      undefined,
      true,
    );
  }
  return await analyzeWithGroq(text, {
    apiKey: groqApiKey,
    model,
    timeoutMs,
    maxCompletionTokens,
  });
}

async function completeJob(
  admin: SupabaseRpc,
  job: ClaimRow,
  result: SentimentResult,
): Promise<void> {
  const { error } = await admin.rpc("feedback_sentiment_complete", {
    p_analysis_id: job.id,
    p_version: job.analysis_version,
    p_sentiment: result.sentiment,
    p_confidence: result.confidence,
    p_topic_sentiments: result.topics,
    p_provider: provider,
    p_model: model,
  });
  if (error) {
    throw new SentimentProviderError(
      sanitizeErrorCode(error.code || error.message),
      "Database rejected sentiment result.",
      undefined,
      true,
    );
  }
}

async function failJob(
  admin: SupabaseRpc,
  job: ClaimRow,
  error: SentimentProviderError,
  attemptCeiling: number,
): Promise<void> {
  const { error: rpcError } = await admin.rpc("feedback_sentiment_fail", {
    p_analysis_id: job.id,
    p_version: job.analysis_version,
    p_error_code: error.code,
    p_retry_after_seconds: error.retryAfterSeconds ?? null,
    p_max_attempts: attemptCeiling,
    p_provider: provider,
    p_model: model,
  });
  if (rpcError) {
    logEvent({
      analysis_id: job.id,
      feedback_id: job.feedback_id,
      status: "failure_update_failed",
      error_code: sanitizeErrorCode(rpcError.code || rpcError.message),
    });
  }
}

function normalizeError(error: unknown): SentimentProviderError {
  if (error instanceof SentimentProviderError) {
    return new SentimentProviderError(
      sanitizeErrorCode(error.code),
      error.message,
      error.retryAfterSeconds,
      error.terminal,
    );
  }
  return new SentimentProviderError(sanitizeErrorCode(String(error)));
}

function logEvent(event: Record<string, unknown>) {
  console.log(JSON.stringify({
    component: "feedback-sentiment",
    ...event,
  }));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
