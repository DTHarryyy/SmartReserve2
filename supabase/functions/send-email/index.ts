import { createClient } from "jsr:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";
import {
  type EmailDeliveryJob,
  isDeliverableAddress,
  isPermanentSmtpError,
  parseLeasedJobs,
  parsePositiveInt,
  renderEmail,
  sanitizeErrorCode,
  smtpErrorCode,
} from "./contract.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const workerKey = Deno.env.get("EMAIL_WORKER_KEY") ?? "";
const enabled =
  (Deno.env.get("EMAIL_ENABLED") ?? "false").toLowerCase() === "true";

// Same Gmail account (and app password) the Auth emails already use.
const smtpHost = Deno.env.get("SMTP_HOST") ?? "smtp.gmail.com";
const smtpPort = parsePositiveInt(Deno.env.get("SMTP_PORT"), 587, 1, 65535);
const smtpUser = Deno.env.get("SMARTRESERVE_SMTP_USERNAME") ?? "";
const smtpPass = Deno.env.get("SMARTRESERVE_SMTP_PASSWORD") ?? "";
const fromName = Deno.env.get("EMAIL_FROM_NAME") ?? "SmartReserve";
const appUrl = Deno.env.get("SMARTRESERVE_APP_URL") ?? "";

const batchSize = parsePositiveInt(
  Deno.env.get("EMAIL_BATCH_SIZE"),
  20,
  1,
  100,
);
const leaseSeconds = parsePositiveInt(
  Deno.env.get("EMAIL_LEASE_SECONDS"),
  120,
  30,
  600,
);
const maxAttempts = parsePositiveInt(
  Deno.env.get("EMAIL_MAX_ATTEMPTS"),
  5,
  1,
  10,
);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-smartreserve-worker-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// deno-lint-ignore no-explicit-any
type SupabaseAdmin = ReturnType<typeof createClient<any>>;

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
      {
        code: "method_not_allowed",
        error: "Method not allowed",
        request_id: requestId,
      },
      405,
    );
  }
  if (
    !workerKey || request.headers.get("x-smartreserve-worker-key") !== workerKey
  ) {
    return json(
      { code: "unauthorized", error: "Unauthorized", request_id: requestId },
      401,
    );
  }
  if (!enabled) {
    return json({ request_id: requestId, disabled: true, claimed: 0, sent: 0 });
  }
  if (!supabaseUrl || !serviceRoleKey || !smtpUser || !smtpPass) {
    return json(
      {
        code: "configuration_error",
        error: "Email worker is not configured.",
        request_id: requestId,
      },
      500,
    );
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  let jobs: EmailDeliveryJob[];
  try {
    jobs = await leaseJobs(admin, requestId);
  } catch (error) {
    return json(
      {
        code: sanitizeErrorCode(error instanceof Error ? error.message : error),
        error: "Could not lease email deliveries.",
        request_id: requestId,
      },
      500,
    );
  }
  if (jobs.length === 0) {
    return json({
      request_id: requestId,
      claimed: 0,
      sent: 0,
      failed: 0,
      retried: 0,
    });
  }

  // One pooled connection per sweep; port 465 is implicit TLS, 587 upgrades
  // with STARTTLS.
  const transport = nodemailer.createTransport({
    host: smtpHost,
    port: smtpPort,
    secure: smtpPort === 465,
    requireTLS: smtpPort !== 465,
    pool: true,
    maxConnections: 1,
    auth: { user: smtpUser, pass: smtpPass },
  });

  let sent = 0;
  let failed = 0;
  let retried = 0;

  for (const job of jobs) {
    const started = Date.now();
    let status: "sent" | "failed" = "sent";
    let errorCode: string | null = null;
    let permanent = false;

    if (!isDeliverableAddress(job.email)) {
      status = "failed";
      errorCode = "invalid_address";
      permanent = true;
    } else {
      const message = renderEmail(job, appUrl);
      try {
        await transport.sendMail({
          from: { name: fromName, address: smtpUser },
          to: message.to,
          subject: message.subject,
          text: message.text,
          html: message.html,
          headers: { "X-SmartReserve-Notification": job.notification_id },
        });
      } catch (error) {
        status = "failed";
        errorCode = smtpErrorCode(error);
        permanent = isPermanentSmtpError(error);
      }
    }

    const { error: completeError } = await admin.rpc(
      "complete_email_delivery",
      {
        p_id: job.id,
        p_status: status,
        p_error_code: errorCode,
        p_permanent: permanent,
        p_max_attempts: maxAttempts,
      },
    );
    if (completeError) {
      logEvent({
        request_id: requestId,
        delivery_id: job.id,
        status: "complete_failed",
        error_code: sanitizeErrorCode(
          completeError.code || completeError.message,
        ),
      });
    }

    if (status === "sent") {
      sent += 1;
    } else if (permanent || job.attempt_count >= maxAttempts) {
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
      error_code: errorCode,
      attempt: job.attempt_count,
      duration_ms: Date.now() - started,
    });
  }

  transport.close();

  return json({
    request_id: requestId,
    claimed: jobs.length,
    sent,
    failed,
    retried,
  });
});

async function leaseJobs(
  admin: SupabaseAdmin,
  requestId: string,
): Promise<EmailDeliveryJob[]> {
  const { data, error } = await admin.rpc("lease_email_deliveries", {
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

// Addresses are never logged; delivery and notification ids are enough to
// trace a send.
function logEvent(event: Record<string, unknown>) {
  console.log(JSON.stringify({ component: "send-email", ...event }));
}
