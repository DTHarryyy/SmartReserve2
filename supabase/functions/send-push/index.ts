import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  buildFcmMessage,
  classifyFcmError,
  parseLeasedJobs,
  parsePositiveInt,
  type PushDeliveryJob,
  sanitizeErrorCode,
} from "./contract.ts";
import { sendFcmMessage } from "./fcm.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const workerKey = Deno.env.get("PUSH_WORKER_KEY") ?? "";
const fcmProjectId = Deno.env.get("FCM_PROJECT_ID") ?? "";
const fcmServiceAccountJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON") ?? "";
const enabled = (Deno.env.get("PUSH_ENABLED") ?? "false").toLowerCase() === "true";

const batchSize = parsePositiveInt(Deno.env.get("PUSH_BATCH_SIZE"), 25, 1, 100);
const leaseSeconds = parsePositiveInt(Deno.env.get("PUSH_LEASE_SECONDS"), 120, 30, 600);
const maxAttempts = parsePositiveInt(Deno.env.get("PUSH_MAX_ATTEMPTS"), 5, 1, 10);
const timeoutMs = parsePositiveInt(
  Deno.env.get("PUSH_PROVIDER_TIMEOUT_MS"),
  8000,
  1000,
  30000,
);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-smartreserve-worker-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type SupabaseAdmin = ReturnType<typeof createClient>;

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
    return json({ request_id: requestId, disabled: true, claimed: 0, sent: 0 });
  }
  if (!supabaseUrl || !serviceRoleKey || !fcmProjectId || !fcmServiceAccountJson) {
    return json(
      { code: "configuration_error", error: "Push worker is not configured.", request_id: requestId },
      500,
    );
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  let jobs: PushDeliveryJob[];
  try {
    jobs = await leaseJobs(admin, requestId);
  } catch (error) {
    return json(
      {
        code: sanitizeErrorCode(error instanceof Error ? error.message : error),
        error: "Could not lease push deliveries.",
        request_id: requestId,
      },
      500,
    );
  }

  let sent = 0;
  let failed = 0;
  let retried = 0;

  for (const job of jobs) {
    const started = Date.now();
    let sentCount = 0;
    const deadTokens: string[] = [];
    let lastErrorCode: string | null = null;

    // A recipient's devices are independent, so send to all of them at once.
    await Promise.all(job.tokens.map(async (token) => {
      try {
        const result = await sendFcmMessage({
          projectId: fcmProjectId,
          serviceAccountJson: fcmServiceAccountJson,
          message: buildFcmMessage(job, token).message,
          timeoutMs,
        });
        if (result.ok) {
          sentCount += 1;
          return;
        }
        const outcome = classifyFcmError(result.status, result.body);
        lastErrorCode = sanitizeErrorCode(extractErrorStatus(result.body) ?? `http_${result.status}`);
        if (outcome === "dead_token") deadTokens.push(token);
      } catch (error) {
        lastErrorCode = sanitizeErrorCode(error instanceof Error ? error.message : error);
      }
    }));

    const status = sentCount > 0 ? "sent" : "failed";
    const { error: completeError } = await admin.rpc("complete_push_delivery", {
      p_id: job.id,
      p_status: status,
      p_sent_count: sentCount,
      p_error_code: status === "sent" ? null : lastErrorCode,
      p_dead_tokens: deadTokens.length > 0 ? deadTokens : null,
      p_max_attempts: maxAttempts,
    });

    if (completeError) {
      logEvent({
        request_id: requestId,
        delivery_id: job.id,
        status: "complete_failed",
        error_code: sanitizeErrorCode(completeError.code || completeError.message),
      });
    }

    if (status === "sent") {
      sent += 1;
    } else if (job.attempt_count >= maxAttempts) {
      failed += 1;
    } else {
      retried += 1;
    }

    logEvent({
      request_id: requestId,
      delivery_id: job.id,
      notification_id: job.notification_id,
      kind: job.kind,
      status,
      tokens: job.tokens.length,
      sent_count: sentCount,
      dead_tokens: deadTokens.length,
      attempt: job.attempt_count,
      duration_ms: Date.now() - started,
    });
  }

  return json({
    request_id: requestId,
    claimed: jobs.length,
    sent,
    failed,
    retried,
  });
});

async function leaseJobs(admin: SupabaseAdmin, requestId: string): Promise<PushDeliveryJob[]> {
  const { data, error } = await admin.rpc("lease_push_deliveries", {
    p_limit: batchSize,
    p_lease_seconds: leaseSeconds,
    p_max_attempts: maxAttempts,
  });
  if (error) {
    logEvent({
      request_id: requestId,
      status: "lease_failed",
      error_code: sanitizeErrorCode(error.code || error.message),
    });
    throw error;
  }
  return parseLeasedJobs(data);
}

function extractErrorStatus(body: unknown): string | undefined {
  if (typeof body !== "object" || body === null) return undefined;
  const error = (body as Record<string, unknown>).error;
  if (typeof error !== "object" || error === null) return undefined;
  const status = (error as Record<string, unknown>).status;
  return typeof status === "string" ? status : undefined;
}

function logEvent(event: Record<string, unknown>) {
  console.log(JSON.stringify({ component: "send-push", ...event }));
}
