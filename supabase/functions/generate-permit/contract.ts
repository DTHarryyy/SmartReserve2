export type PermitTemplateKind = "internal" | "external";

export type PermitOccurrence = {
  starts_at: string;
  ends_at: string;
};

export type PermitItem = {
  row_code: string;
  label: string;
  requested_quantity?: number | null;
  duration_minutes?: number | null;
  billing_basis?: string | null;
  unit_amount_centavos?: number | null;
  line_total_centavos?: number | null;
};

export type PermitSnapshot = {
  template_kind: PermitTemplateKind;
  template_sha256: string;
  requester_id: string;
  requester_name: string;
  requester_type: string;
  requester_unit: string;
  purpose: string;
  headcount: number;
  occurrences: PermitOccurrence[];
  items: PermitItem[];
  total_amount_centavos: number;
  external_company_organization?: string | null;
  external_complete_address?: string | null;
  external_contact_numbers?: string[] | null;
  external_admission_fee_centavos?: number | null;
  user_signed_at: string;
};

export const templateHashes: Record<PermitTemplateKind, string> = {
  internal: "4732b1b07c455531615faa3de2b6e2dd2631ec2e4fa609c34ff99e241f64cb58",
  external: "bf328cc2b7eadafae9be130e2ec93342c05dea78a3579f1fccbb58ce1d5767aa",
};

export const normalizeText = (value: unknown) =>
  String(value ?? "")
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();

const phtParts = (iso: string) =>
  new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Manila",
    year: "numeric",
    month: "long",
    day: "numeric",
  }).format(new Date(iso));

export const formatDate = (iso: string) => phtParts(iso);

export const formatTime = (iso: string) =>
  new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Manila",
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  }).format(new Date(iso));

const dayKey = (iso: string) =>
  new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Manila",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date(iso));

const weekday = (iso: string) =>
  new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Manila",
    weekday: "long",
  }).format(new Date(iso));

export function formatDateRange(firstIso: string, lastIso: string) {
  const first = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Manila",
    month: "long",
    day: "numeric",
  }).format(new Date(firstIso));
  return `${first}–${formatDate(lastIso)}`;
}

export function formatSchedule(occurrences: PermitOccurrence[]) {
  if (!occurrences.length) return "";
  const ordered = [...occurrences].sort((a, b) =>
    a.starts_at.localeCompare(b.starts_at)
  );
  if (ordered.length === 1) {
    const only = ordered[0];
    return `${formatDate(only.starts_at)} · ${formatTime(only.starts_at)}–${
      formatTime(only.ends_at)
    }`;
  }
  const sameTimes = ordered.every((item) =>
    formatTime(item.starts_at) === formatTime(ordered[0].starts_at) &&
    formatTime(item.ends_at) === formatTime(ordered[0].ends_at)
  );
  const weekly = ordered.slice(1).every((item, index) => {
    const previous = new Date(`${dayKey(ordered[index].starts_at)}T00:00:00Z`);
    const current = new Date(`${dayKey(item.starts_at)}T00:00:00Z`);
    return (current.getTime() - previous.getTime()) / 86400000 === 7;
  });
  if (sameTimes && weekly) {
    const day = weekday(ordered[0].starts_at);
    return `${
      formatDateRange(ordered[0].starts_at, ordered.at(-1)!.starts_at)
    } · ` +
      `${ordered.length} weekly ${day}s · ${formatTime(ordered[0].starts_at)}–${
        formatTime(ordered[0].ends_at)
      }`;
  }
  return ordered.map((item) =>
    `${formatDate(item.starts_at)} ${formatTime(item.starts_at)}–${
      formatTime(item.ends_at)
    }`
  ).join("; ");
}

export const formatMoney = (centavos: number, prefix = false) => {
  const amount = (Number(centavos || 0) / 100).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
  return prefix ? `PHP ${amount}` : amount;
};

export const formatDuration = (minutes: number | null | undefined) => {
  const hours = Number(minutes || 0) / 60;
  return `${hours.toLocaleString("en-US", { maximumFractionDigits: 1 })} HRS`;
};

export const formatBasis = (basis: string | null | undefined) => ({
  hourly: "HOUR/S",
  per_occurrence: "PER OCC.",
  per_reservation: "PER RES.",
  included: "INCLUDED",
}[String(basis ?? "")] ?? normalizeText(basis).toUpperCase());

export async function sha256(bytes: Uint8Array) {
  return Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", bytes.slice().buffer)),
  )
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
