// Pure, network-free pieces of the send-push worker: FCM HTTP v1 message
// construction from a leased push_deliveries row, and classification of an
// FCM error response into what the caller should do about it. Kept apart
// from index.ts (which needs Deno's crypto + network) so this half can be
// unit tested directly, matching feedback-sentiment/contract.ts.

export type PushDeliveryJob = {
  id: string;
  notification_id: string;
  recipient_id: string;
  attempt_count: number;
  kind: string;
  title: string;
  body: string;
  request_id: string | null;
  tokens: string[];
};

export type FcmMessage = {
  message: {
    token: string;
    notification: { title: string; body: string };
    data: Record<string, string>;
  };
};

export function buildFcmMessage(job: PushDeliveryJob, token: string): FcmMessage {
  const data: Record<string, string> = {
    kind: job.kind,
    notification_id: job.notification_id,
  };
  if (job.request_id) data.request_id = job.request_id;

  return {
    message: {
      token,
      notification: {
        title: job.title,
        body: job.body,
      },
      data,
    },
  };
}

export type FcmOutcome = "retry" | "dead_token" | "fatal";

const deadTokenCodes = new Set(["UNREGISTERED", "INVALID_ARGUMENT", "SENDER_ID_MISMATCH"]);
const retryCodes = new Set(["UNAVAILABLE", "INTERNAL", "QUOTA_EXCEEDED"]);

export function classifyFcmError(status: number, body: unknown): FcmOutcome {
  const errorCode = extractFcmErrorCode(body);
  if (errorCode && deadTokenCodes.has(errorCode)) return "dead_token";
  if (status === 429 || status >= 500) return "retry";
  if (errorCode && retryCodes.has(errorCode)) return "retry";
  return "fatal";
}

function extractFcmErrorCode(body: unknown): string | undefined {
  if (!isRecord(body)) return undefined;
  const error = body.error;
  if (!isRecord(error)) return undefined;
  const details = error.details;
  if (Array.isArray(details)) {
    for (const detail of details) {
      if (isRecord(detail) && typeof detail.errorCode === "string") {
        return detail.errorCode;
      }
    }
  }
  return typeof error.status === "string" ? error.status : undefined;
}

export function sanitizeErrorCode(value: unknown): string {
  const raw = typeof value === "string" && value.trim().length > 0
    ? value.trim().toLowerCase()
    : "send_failed";
  const normalized = raw.replace(/[^a-z0-9_]+/g, "_").replace(/^_+|_+$/g, "")
    .slice(0, 80);
  return normalized.length >= 2 ? normalized : "send_failed";
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

export function parseLeasedJobs(data: unknown): PushDeliveryJob[] {
  const rows = isRecord(data) && Array.isArray(data.rows) ? data.rows : [];
  return rows
    .filter(isRecord)
    .map((row) => ({
      id: String(row.id),
      notification_id: String(row.notification_id),
      recipient_id: String(row.recipient_id),
      attempt_count: Number(row.attempt_count) || 1,
      kind: typeof row.kind === "string" ? row.kind : "",
      title: typeof row.title === "string" ? row.title : "",
      body: typeof row.body === "string" ? row.body : "",
      request_id: typeof row.request_id === "string" ? row.request_id : null,
      tokens: Array.isArray(row.tokens)
        ? row.tokens.filter((t): t is string => typeof t === "string")
        : [],
    }))
    .filter((row) => row.id && row.notification_id && row.tokens.length > 0);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
