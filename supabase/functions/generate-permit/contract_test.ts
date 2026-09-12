import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { PDFDocument } from "npm:pdf-lib@1.17.1";
import {
  formatBasis,
  formatDuration,
  formatSchedule,
  sha256,
  templateHashes,
} from "./contract.ts";
import type { PermitSnapshot } from "./contract.ts";
import { renderPermit } from "./permit_layout.ts";

for (
  const [kind, file] of [
    ["internal", "internal Permit.pdf"],
    ["external", "External Permit.pdf"],
  ] as const
) {
  Deno.test(`${kind} deployment template is hash-locked one-page A4`, async () => {
    const bytes = await Deno.readFile(
      new URL(`./templates/${file}`, import.meta.url),
    );
    assertEquals(await sha256(bytes), templateHashes[kind]);
    const pdf = await PDFDocument.load(bytes);
    assertEquals(pdf.getPageCount(), 1);
    const page = pdf.getPage(0);
    assertEquals(Math.abs(page.getMediaBox().width - 595.2756) < 0.2, true);
    assertEquals(Math.abs(page.getMediaBox().height - 841.8898) < 0.2, true);
    assertEquals(Math.abs(page.getCropBox().width - 595.2756) < 0.2, true);
    assertEquals(Math.abs(page.getCropBox().height - 841.8898) < 0.2, true);
    assertEquals(page.getRotation().angle, 0);
  });
}

Deno.test("weekly schedule and billing labels use official compact forms", () => {
  const schedule = formatSchedule([
    { starts_at: "2026-09-01T01:00:00Z", ends_at: "2026-09-01T04:00:00Z" },
    { starts_at: "2026-09-08T01:00:00Z", ends_at: "2026-09-08T04:00:00Z" },
    { starts_at: "2026-09-15T01:00:00Z", ends_at: "2026-09-15T04:00:00Z" },
  ]);
  assertEquals(schedule.includes("3 weekly Tuesdays"), true);
  assertEquals(formatDuration(450), "7.5 HRS");
  assertEquals(formatBasis("per_occurrence"), "PER OCC.");
});

Deno.test("both official templates accept bounded overlays without adding pages", async () => {
  const signature = Uint8Array.from(
    atob(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL1WQAAAABJRU5ErkJggg==",
    ),
    (value) => value.charCodeAt(0),
  );
  const base = {
    requester_id: "00000000-0000-0000-0000-000000000001",
    requester_name: "Maria Dela Cruz",
    requester_type: "student",
    requester_unit: "College of Information and Computing Sciences",
    purpose: "Faculty and student orientation",
    headcount: 40,
    occurrences: [{
      starts_at: "2026-09-01T01:00:00Z",
      ends_at: "2026-09-01T04:00:00Z",
    }],
    total_amount_centavos: 0,
    user_signed_at: "2026-08-28T03:00:00Z",
  };
  const fixtures: PermitSnapshot[] = [{
    ...base,
    template_kind: "internal",
    template_sha256: templateHashes.internal,
    items: [{
      row_code: "facility:conference_room",
      label: "Faculty Conference Room",
    }],
  }, {
    ...base,
    template_kind: "external",
    template_sha256: templateHashes.external,
    requester_type: "external_renter",
    requester_unit: "",
    total_amount_centavos: 250000,
    external_company_organization: "Individual",
    external_complete_address: "Aparri, Cagayan",
    external_contact_numbers: ["09171234567"],
    external_admission_fee_centavos: 0,
    items: [{
      row_code: "external:gym_auditorium",
      label: "University Auditorium",
      duration_minutes: 180,
      billing_basis: "hourly",
      unit_amount_centavos: 250000,
      line_total_centavos: 250000,
    }],
  }];
  for (const fixture of fixtures) {
    const file = fixture.template_kind === "internal"
      ? "internal Permit.pdf"
      : "External Permit.pdf";
    const template = await Deno.readFile(
      new URL(`./templates/${file}`, import.meta.url),
    );
    const signatures = fixture.template_kind === "internal"
      ? [signature, signature]
      : [signature, signature, signature];
    const output = await renderPermit(template, fixture, signatures);
    assertEquals((await PDFDocument.load(output)).getPageCount(), 1);
    assertEquals(await sha256(template), templateHashes[fixture.template_kind]);
  }
});
