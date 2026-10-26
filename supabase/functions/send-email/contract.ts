// Pure, network-free pieces of the send-email worker: parsing leased
// email_deliveries rows, rendering a notification into a branded email, and
// classifying SMTP failures. Kept apart from index.ts (which needs the
// network) so this half can be unit tested directly, matching
// send-push/contract.ts.

export type EmailDeliveryJob = {
  id: string;
  notification_id: string;
  recipient_id: string;
  attempt_count: number;
  kind: string;
  title: string;
  body: string;
  request_id: string | null;
  email: string;
  full_name: string;
};

export type RenderedEmail = {
  to: string;
  subject: string;
  text: string;
  html: string;
};

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function parseLeasedJobs(data: unknown): EmailDeliveryJob[] {
  const rows = isRecord(data) && Array.isArray(data.rows) ? data.rows : [];
  return rows
    .filter(isRecord)
    .map((row) => ({
      id: String(row.id ?? ""),
      notification_id: String(row.notification_id ?? ""),
      recipient_id: String(row.recipient_id ?? ""),
      attempt_count: Number(row.attempt_count) || 1,
      kind: typeof row.kind === "string" ? row.kind : "",
      title: typeof row.title === "string" ? row.title : "",
      body: typeof row.body === "string" ? row.body : "",
      request_id: typeof row.request_id === "string" ? row.request_id : null,
      email: typeof row.email === "string" ? row.email.trim() : "",
      full_name: typeof row.full_name === "string" ? row.full_name.trim() : "",
    }))
    .filter((row) => row.id && row.notification_id);
}

export function isDeliverableAddress(email: string): boolean {
  return email.length <= 254 && emailPattern.test(email);
}

export function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

// Subjects are a single header line: strip CR/LF so a notification title can
// never inject extra headers, and keep them short enough for inbox previews.
export function subjectFor(job: EmailDeliveryJob): string {
  const title = job.title.replace(/[\r\n]+/g, " ").trim() || "New notification";
  const subject = `SmartReserve: ${title}`;
  return subject.length > 140 ? `${subject.slice(0, 139)}…` : subject;
}

export function renderEmail(
  job: EmailDeliveryJob,
  appUrl: string,
): RenderedEmail {
  const greeting = job.full_name ? `Hi ${job.full_name},` : "Hi,";
  const link = appUrl.trim();
  const text = [
    greeting,
    "",
    job.title,
    job.body,
    "",
    link ? `Open SmartReserve: ${link}` : "",
    "",
    "You are receiving this because email notifications are on for your " +
    "SmartReserve account. Turn them off under Account › Notifications.",
  ].filter((line, index, all) => line !== "" || all[index - 1] !== "").join(
    "\n",
  );

  const paragraphs = job.body
    .split(/\n{2,}/)
    .map((part) =>
      `<p style="margin:0 0 12px;color:#475467;font-size:15px;line-height:24px;">${
        escapeHtml(part).replaceAll("\n", "<br>")
      }</p>`
    )
    .join("");
  const button = link
    ? `<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:20px 0 8px;"><tr><td style="background:#1b58a6;border-radius:8px;"><a href="${
      escapeHtml(link)
    }" style="display:inline-block;padding:12px 20px;color:#ffffff;font-size:14px;font-weight:700;text-decoration:none;">Open SmartReserve</a></td></tr></table>`
    : "";

  const html = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${escapeHtml(job.title)}</title>
  </head>
  <body style="margin:0;padding:0;background:#f4f5f7;color:#10141a;font-family:Arial,Helvetica,sans-serif;">
    <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="background:#f4f5f7;">
      <tr>
        <td align="center" style="padding:32px 16px;">
          <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="max-width:560px;">
            <tr>
              <td style="padding:22px 24px;background:#101418;border-radius:14px 14px 0 0;">
                <table role="presentation" cellspacing="0" cellpadding="0" border="0">
                  <tr>
                    <td width="36" height="36" align="center" valign="middle" style="width:36px;height:36px;background:#1b58a6;border-radius:9px;color:#ffffff;font-size:16px;font-weight:700;">S</td>
                    <td style="padding-left:11px;color:#ffffff;font-size:16px;font-weight:700;line-height:20px;">SmartReserve<br><span style="color:#c3c9d2;font-size:10px;font-weight:400;letter-spacing:.7px;">CAGAYAN STATE UNIVERSITY — APARRI</span></td>
                  </tr>
                </table>
              </td>
            </tr>
            <tr>
              <td style="padding:32px 28px;background:#ffffff;border:1px solid #e4e7ec;border-top:0;border-radius:0 0 14px 14px;">
                <p style="margin:0 0 12px;color:#667085;font-size:14px;line-height:22px;">${
    escapeHtml(greeting)
  }</p>
                <h1 style="margin:0 0 12px;font-size:22px;line-height:28px;color:#10141a;">${
    escapeHtml(job.title)
  }</h1>
                ${paragraphs}
                ${button}
                <p style="margin:16px 0 0;color:#98a2b3;font-size:12px;line-height:20px;">You are receiving this because email notifications are on for your SmartReserve account. Turn them off under Account › Notifications.</p>
              </td>
            </tr>
            <tr>
              <td align="center" style="padding:18px 8px 0;color:#98a2b3;font-size:11px;line-height:18px;">SmartReserve · Cagayan State University — Aparri</td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
  </body>
</html>`;

  return { to: job.email, subject: subjectFor(job), text, html };
}

// SMTP reply codes: 5xx is permanent (bad mailbox, policy rejection) except
// auth failures, which are a configuration problem worth retrying once the
// operator fixes the app password; 4xx and network errors are transient.
export function isPermanentSmtpError(error: unknown): boolean {
  if (!isRecord(error)) return false;
  const code = Number(error.responseCode);
  if (!Number.isFinite(code)) return false;
  if (code === 530 || code === 534 || code === 535) return false;
  return code >= 500 && code < 600;
}

export function smtpErrorCode(error: unknown): string {
  if (isRecord(error)) {
    if (Number.isFinite(Number(error.responseCode))) {
      return `smtp_${Number(error.responseCode)}`;
    }
    if (typeof error.code === "string") return sanitizeErrorCode(error.code);
  }
  return sanitizeErrorCode(error instanceof Error ? error.message : error);
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
