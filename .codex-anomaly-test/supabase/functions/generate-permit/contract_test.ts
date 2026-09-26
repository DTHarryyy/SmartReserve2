import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { PDFArray, PDFDocument, PDFRawStream } from "npm:pdf-lib@1.17.1";
import { PNG } from "npm:pngjs@7.0.0";
import jpeg from "npm:jpeg-js@0.4.4";
import { Buffer } from "node:buffer";
import {
  formatBasis,
  formatDuration,
  formatSchedule,
  sha256,
  templateHashes,
} from "./contract.ts";
import type { PermitSnapshot } from "./contract.ts";
import { cropSignatureMargins, renderPermit } from "./permit_layout.ts";

function pageContentStreams(document: PDFDocument) {
  const contents = document.getPage(0).node.Contents();
  if (!contents) return [];
  const entries = contents instanceof PDFArray
    ? contents.asArray()
    : [contents];
  return entries.map((entry) => document.context.lookup(entry))
    .filter((entry): entry is PDFRawStream => entry instanceof PDFRawStream)
    .map((entry) => entry.getContents());
}

function equalBytes(left: Uint8Array, right: Uint8Array) {
  return left.length === right.length &&
    left.every((byte, index) => byte === right[index]);
}

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

Deno.test("PNG and JPEG signatures are cropped to nonblank content", () => {
  const width = 40;
  const height = 20;
  const rgba = new Uint8Array(width * height * 4).fill(255);
  for (let y = 8; y <= 11; y++) {
    for (let x = 14; x <= 25; x++) {
      const offset = (y * width + x) * 4;
      rgba[offset] = 0;
      rgba[offset + 1] = 0;
      rgba[offset + 2] = 0;
    }
  }
  const sourcePng = new PNG({ width, height });
  sourcePng.data.set(rgba);
  const pngResult = PNG.sync.read(
    Buffer.from(cropSignatureMargins(PNG.sync.write(sourcePng))),
  );
  const jpegBytes = jpeg.encode({ width, height, data: rgba }, 95).data;
  const jpegResult = PNG.sync.read(
    Buffer.from(cropSignatureMargins(jpegBytes)),
  );
  for (const result of [pngResult, jpegResult]) {
    assertEquals(result.width < width, true);
    assertEquals(result.height < height, true);
  }
});

Deno.test("both official templates accept bounded overlays without adding pages", async () => {
  const signatureImage = new PNG({ width: 4, height: 2 });
  for (let offset = 0; offset < signatureImage.data.length; offset += 4) {
    signatureImage.data[offset + 3] = 255;
  }
  const signature = new Uint8Array(PNG.sync.write(signatureImage));
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
    const originalStreams = pageContentStreams(
      await PDFDocument.load(template),
    );
    const signatures = fixture.template_kind === "internal"
      ? [signature, signature]
      : [signature, signature, signature];
    const output = await renderPermit(template, fixture, signatures);
    const rendered = await PDFDocument.load(output);
    assertEquals(rendered.getPageCount(), 1);
    const renderedStreams = pageContentStreams(rendered);
    assertEquals(
      originalStreams.every((source) =>
        renderedStreams.some((candidate) => equalBytes(source, candidate))
      ),
      true,
      "the original template page content streams must remain byte-identical",
    );
    assertEquals(await sha256(template), templateHashes[fixture.template_kind]);
  }
});

Deno.test("external permit renders the reported misaligned-overlay reservation without error", async () => {
  const signatureImage = new PNG({ width: 4, height: 2 });
  for (let offset = 0; offset < signatureImage.data.length; offset += 4) {
    signatureImage.data[offset + 3] = 255;
  }
  const signature = new Uint8Array(PNG.sync.write(signatureImage));
  // Exact values from the reservation that produced a permit with fields
  // drawn on top of / behind the template's own printed labels.
  const fixture: PermitSnapshot = {
    template_kind: "external",
    template_sha256: templateHashes.external,
    requester_id: "00000000-0000-0000-0000-000000000003",
    requester_name: "harry",
    requester_type: "external_renter",
    requester_unit: "",
    purpose: "ASDASD",
    headcount: 20,
    occurrences: [{
      starts_at: "2026-09-21T00:00:00+08:00",
      ends_at: "2026-09-21T01:00:00+08:00",
    }],
    items: [{
      row_code: "external:avr",
      label: "AVR",
      duration_minutes: 60,
      billing_basis: "hourly",
      unit_amount_centavos: 100000,
      line_total_centavos: 100000,
    }],
    total_amount_centavos: 100000,
    external_company_organization: "Individual",
    external_complete_address: "DSASD",
    external_contact_numbers: ["12321231"],
    external_admission_fee_centavos: 0,
    user_signed_at: "2026-09-20T00:00:00+08:00",
  };
  const template = await Deno.readFile(
    new URL(`./templates/External Permit.pdf`, import.meta.url),
  );
  const output = await renderPermit(template, fixture, [
    signature,
    signature,
    signature,
  ]);
  const rendered = await PDFDocument.load(output);
  assertEquals(rendered.getPageCount(), 1);
});
