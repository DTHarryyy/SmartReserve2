import {
  PDFDocument,
  PDFFont,
  PDFImage,
  PDFPage,
  rgb,
  StandardFonts,
} from "npm:pdf-lib@1.17.1";
import { PNG } from "npm:pngjs@7.0.0";
import jpeg from "npm:jpeg-js@0.4.4";
import { Buffer } from "node:buffer";
import {
  formatBasis,
  formatDate,
  formatDateRange,
  formatDuration,
  formatMoney,
  formatSchedule,
  formatTime,
  normalizeText,
  PermitItem,
  PermitSnapshot,
} from "./contract.ts";

type Box = { x: number; y: number; width: number; height: number };
const ink = rgb(0.03, 0.03, 0.03);

export const permitOverlayMasks: Record<"internal" | "external", Box[]> = {
  internal: [
    { x: 404, y: 42, width: 134, height: 18 },
    { x: 57, y: 203, width: 40, height: 107 },
    { x: 181, y: 268, width: 105, height: 35 },
    { x: 308, y: 203, width: 39, height: 111 },
    { x: 430, y: 278, width: 108, height: 29 },
    { x: 57, y: 347, width: 481, height: 17 },
    { x: 57, y: 399, width: 481, height: 43 },
    { x: 57, y: 525, width: 240, height: 24 },
    { x: 134, y: 574, width: 225, height: 18 },
    { x: 179, y: 640, width: 259, height: 26 },
  ],
  external: [
    { x: 105, y: 125, width: 321, height: 15 },
    { x: 460, y: 125, width: 123, height: 15 },
    { x: 161, y: 141, width: 422, height: 16 },
    { x: 98, y: 157, width: 485, height: 16 },
    { x: 95, y: 173, width: 488, height: 16 },
    ...[223, 243, 263, 282, 302, 322, 341, 361].map((y) => ({
      x: 18,
      y,
      width: 565,
      height: 19,
    })),
    { x: 409, y: 451, width: 159, height: 18 },
    { x: 18, y: 492, width: 565, height: 22 },
    { x: 165, y: 520, width: 181, height: 24 },
    { x: 352, y: 520, width: 86, height: 24 },
    { x: 443, y: 520, width: 140, height: 24 },
    { x: 217, y: 553, width: 67, height: 21 },
    { x: 392, y: 553, width: 191, height: 21 },
    { x: 400, y: 617, width: 135, height: 26 },
    { x: 135, y: 681, width: 100, height: 18 },
    { x: 314, y: 681, width: 13, height: 18 },
    { x: 217, y: 704, width: 191, height: 24 },
    { x: 171, y: 752, width: 248, height: 27 },
  ],
};

const pageKinds = new WeakMap<PDFPage, "internal" | "external">();

function assertInsideOverlayMask(page: PDFPage, box: Box) {
  const kind = pageKinds.get(page);
  if (!kind) throw new Error("Permit page has no overlay-mask context");
  const epsilon = 0.01;
  const inside = permitOverlayMasks[kind].some((mask) =>
    box.x >= mask.x - epsilon && box.y >= mask.y - epsilon &&
    box.x + box.width <= mask.x + mask.width + epsilon &&
    box.y + box.height <= mask.y + mask.height + epsilon
  );
  if (!inside) throw new Error(`Overlay escaped declared ${kind} mask`);
}

const pdfY = (page: PDFPage, box: Box) => page.getHeight() - box.y - box.height;

function linesFor(font: PDFFont, value: string, size: number, width: number) {
  const words = normalizeText(value).split(" ").filter(Boolean);
  const lines: string[] = [];
  for (const word of words) {
    const candidate = lines.length ? `${lines.at(-1)} ${word}` : word;
    if (font.widthOfTextAtSize(candidate, size) <= width) {
      if (lines.length) lines[lines.length - 1] = candidate;
      else lines.push(candidate);
    } else {
      lines.push(word);
    }
  }
  return lines;
}

function drawFitted(
  page: PDFPage,
  font: PDFFont,
  value: unknown,
  box: Box,
  options: {
    size?: number;
    minSize?: number;
    maxLines?: number;
    align?: "left" | "center";
    field?: string;
  } = {},
) {
  assertInsideOverlayMask(page, box);
  const text = normalizeText(value);
  if (!text) throw new Error("A required permit field is blank");
  const preferred = options.size ?? 9;
  const minimum = options.minSize ?? 6.5;
  const maxLines = options.maxLines ?? 1;
  for (let size = preferred; size >= minimum; size -= 0.25) {
    const lines = maxLines === 1
      ? [text]
      : linesFor(font, text, size, box.width);
    const lineHeight = size * 1.12;
    if (
      lines.length > maxLines || lines.length * lineHeight > box.height ||
      lines.some((line) => font.widthOfTextAtSize(line, size) > box.width)
    ) continue;
    lines.forEach((line, index) => {
      const width = font.widthOfTextAtSize(line, size);
      const x = options.align === "center"
        ? box.x + (box.width - width) / 2
        : box.x;
      page.drawText(line, {
        x,
        y: pdfY(page, box) + box.height - size - index * lineHeight,
        size,
        font,
        color: ink,
      });
    });
    return;
  }
  throw new Error(`field_does_not_fit:${options.field ?? "unknown"}`);
}

function check(
  page: PDFPage,
  font: PDFFont,
  x: number,
  y: number,
  width = 40,
  height = 20,
) {
  drawFitted(page, font, "X", { x, y, width, height }, {
    size: 10,
    minSize: 10,
    align: "center",
  });
}

export function cropSignatureMargins(bytes: Uint8Array) {
  const png = bytes.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10]
    .every((byte, index) => bytes[index] === byte);
  const jpg = bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 &&
    bytes[2] === 0xff;
  if (!png && !jpg) throw new Error("Signature is not a valid PNG or JPEG");
  const decoded = png
    ? PNG.sync.read(Buffer.from(bytes))
    : jpeg.decode(bytes, { useTArray: true, formatAsRGBA: true });
  const { width, height, data } = decoded;
  let left = width;
  let top = height;
  let right = -1;
  let bottom = -1;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const offset = (y * width + x) * 4;
      const alpha = data[offset + 3];
      const blank = alpha <= 8 ||
        (data[offset] >= 248 && data[offset + 1] >= 248 &&
          data[offset + 2] >= 248);
      if (blank) continue;
      left = Math.min(left, x);
      right = Math.max(right, x);
      top = Math.min(top, y);
      bottom = Math.max(bottom, y);
    }
  }
  if (right < left || bottom < top) throw new Error("Signature image is blank");
  const padding = Math.max(1, Math.round(Math.min(width, height) * 0.01));
  left = Math.max(0, left - padding);
  top = Math.max(0, top - padding);
  right = Math.min(width - 1, right + padding);
  bottom = Math.min(height - 1, bottom + padding);
  const output = new PNG({
    width: right - left + 1,
    height: bottom - top + 1,
  });
  for (let y = top; y <= bottom; y++) {
    const sourceStart = (y * width + left) * 4;
    const sourceEnd = (y * width + right + 1) * 4;
    const targetStart = (y - top) * output.width * 4;
    output.data.set(data.subarray(sourceStart, sourceEnd), targetStart);
  }
  return new Uint8Array(PNG.sync.write(output));
}

async function embedImage(document: PDFDocument, bytes: Uint8Array) {
  return document.embedPng(cropSignatureMargins(bytes));
}

function drawImage(page: PDFPage, image: PDFImage, box: Box) {
  assertInsideOverlayMask(page, box);
  const scale = Math.min(box.width / image.width, box.height / image.height);
  const width = image.width * scale;
  const height = image.height * scale;
  page.drawImage(image, {
    x: box.x + (box.width - width) / 2,
    y: pdfY(page, box) + (box.height - height) / 2,
    width,
    height,
  });
}

const internalFacilityRows: Record<string, [number, number]> = {
  audio_visual_main_hall: [57, 203],
  conference_room: [57, 241],
  other: [57, 265],
};
const internalEquipmentRows: Record<string, [number, number]> = {
  sound_system: [308, 203],
  overhead_projector: [308, 227],
  lcd_accessories: [308, 251],
  other: [308, 275],
};

async function renderInternal(
  document: PDFDocument,
  snapshot: PermitSnapshot,
  signatures: Uint8Array[],
) {
  const page = document.getPage(0);
  pageKinds.set(page, "internal");
  const font = await document.embedFont(StandardFonts.Helvetica);
  const bold = await document.embedFont(StandardFonts.HelveticaBold);
  drawFitted(page, font, formatDate(snapshot.user_signed_at), {
    x: 404,
    y: 42,
    width: 134,
    height: 18,
  });
  const facility = snapshot.items.find((item) =>
    item.row_code.startsWith("facility:")
  );
  if (!facility) throw new Error("Facility permit mapping is missing");
  const facilityCode = facility.row_code.split(":")[1];
  const facilityRow = internalFacilityRows[facilityCode];
  if (!facilityRow) {
    throw new Error(`Unsupported internal facility row: ${facilityCode}`);
  }
  check(
    page,
    bold,
    facilityRow[0],
    facilityRow[1],
    40,
    facilityCode === "audio_visual_main_hall" ? 38 : 24,
  );
  if (facilityCode === "other") {
    drawFitted(page, font, facility.label, {
      x: 181,
      y: 268,
      width: 105,
      height: 35,
    }, { size: 8, maxLines: 2, field: "facilities_other" });
  }
  const equipment = snapshot.items.filter((item) =>
    item.row_code.startsWith("equipment:")
  );
  for (const item of equipment) {
    const code = item.row_code.split(":")[1];
    const row = internalEquipmentRows[code];
    if (!row) throw new Error(`Unsupported internal equipment row: ${code}`);
    check(page, bold, row[0], row[1], 39, 24);
  }
  const others = equipment.filter((item) => item.row_code.endsWith(":other"))
    .map((item) => item.label);
  if (others.length) {
    drawFitted(page, font, others.join(", "), {
      x: 430,
      y: 278,
      width: 108,
      height: 29,
    }, { size: 8, maxLines: 2, field: "equipment_other" });
  }
  drawFitted(page, font, formatSchedule(snapshot.occurrences), {
    x: 57,
    y: 347,
    width: 481,
    height: 17,
  }, { size: 9, field: "requested_date_of_use" });
  drawFitted(page, font, snapshot.purpose, {
    x: 57,
    y: 399,
    width: 481,
    height: 43,
  }, { size: 9.5, maxLines: 2, field: "purpose" });
  drawFitted(page, font, snapshot.requester_name, {
    x: 57,
    y: 539,
    width: 240,
    height: 10,
  }, { size: 8, field: "requester_name" });
  drawFitted(page, font, snapshot.requester_unit, {
    x: 134,
    y: 574,
    width: 225,
    height: 18,
  }, { size: 9, field: "office_college" });
  drawImage(page, await embedImage(document, signatures[0]), {
    x: 57,
    y: 525,
    width: 240,
    height: 15,
  });
  drawImage(page, await embedImage(document, signatures[1]), {
    x: 179,
    y: 640,
    width: 259,
    height: 26,
  });
}

const externalRows = [
  "gym_auditorium",
  "tables_chairs",
  "lcd_projector",
  "avr",
  "led_video_wall",
  "accommodation",
  "love_hall",
  "other",
];
const externalYs = [223, 243, 263, 282, 302, 322, 341, 361];

async function renderExternal(
  document: PDFDocument,
  snapshot: PermitSnapshot,
  signatures: Uint8Array[],
) {
  const page = document.getPage(0);
  pageKinds.set(page, "external");
  const font = await document.embedFont(StandardFonts.TimesRoman);
  const bold = await document.embedFont(StandardFonts.TimesRomanBold);
  drawFitted(page, font, snapshot.requester_name, {
    x: 105,
    y: 125,
    width: 321,
    height: 15,
  }, { size: 8.5, field: "requesting_party" });
  drawFitted(page, font, formatDate(snapshot.user_signed_at), {
    x: 460,
    y: 125,
    width: 123,
    height: 15,
  }, { size: 8 });
  drawFitted(page, font, snapshot.external_company_organization, {
    x: 161,
    y: 141,
    width: 422,
    height: 16,
  }, { size: 8.5, field: "company_organization" });
  drawFitted(page, font, snapshot.external_complete_address, {
    x: 98,
    y: 157,
    width: 485,
    height: 16,
  }, { size: 8.5, field: "complete_address" });
  drawFitted(page, font, snapshot.external_contact_numbers?.join(" / "), {
    x: 95,
    y: 173,
    width: 488,
    height: 16,
  }, { size: 8.5, field: "contact_numbers" });
  for (const item of snapshot.items) {
    const code = item.row_code.includes(":")
      ? item.row_code.split(":")[1]
      : item.row_code;
    const index = externalRows.indexOf(code);
    if (index < 0) throw new Error(`Unsupported external permit row: ${code}`);
    const y = externalYs[index];
    check(page, bold, 25, y, 13, 18);
    if (code === "other") {
      drawFitted(page, font, item.label, { x: 140, y, width: 85, height: 19 }, {
        size: 7.5,
        field: "other_description",
      });
    }
    if (code === "tables_chairs") {
      drawFitted(page, font, item.requested_quantity, {
        x: 181,
        y,
        width: 44,
        height: 19,
      }, { size: 8, align: "center" });
    }
    drawFitted(page, font, formatDuration(item.duration_minutes), {
      x: 228,
      y,
      width: 47,
      height: 19,
    }, { size: 7, align: "center" });
    drawFitted(page, font, formatBasis(item.billing_basis), {
      x: 299,
      y,
      width: 51,
      height: 19,
    }, { size: 6.8, align: "center" });
    drawFitted(page, font, formatMoney(item.unit_amount_centavos ?? 0), {
      x: 395,
      y,
      width: 42,
      height: 19,
    }, { size: 7, align: "center" });
    drawFitted(page, font, formatMoney(item.line_total_centavos ?? 0), {
      x: 460,
      y,
      width: 112,
      height: 19,
    }, { size: 7, align: "center" });
  }
  drawFitted(page, bold, formatMoney(snapshot.total_amount_centavos), {
    x: 409,
    y: 451,
    width: 159,
    height: 18,
  }, { size: 9, align: "center" });
  drawFitted(page, font, snapshot.purpose, {
    x: 18,
    y: 492,
    width: 565,
    height: 22,
  }, { size: 8.5, maxLines: 2, field: "purposes" });
  const ordered = [...snapshot.occurrences].sort((a, b) =>
    a.starts_at.localeCompare(b.starts_at)
  );
  const weekly = ordered.length > 1 &&
    ordered.slice(1).every((item, index) =>
      Math.round(
        (new Date(item.starts_at).getTime() -
          new Date(ordered[index].starts_at).getTime()) / 86400000,
      ) === 7
    );
  const dates = weekly
    ? `${
      formatDateRange(ordered[0].starts_at, ordered.at(-1)!.starts_at)
    } · ${ordered.length} weekly`
    : ordered.map((item) => formatDate(item.starts_at)).join(", ");
  drawFitted(page, font, dates, { x: 165, y: 520, width: 181, height: 24 }, {
    size: 8,
    field: "inclusive_dates",
  });
  const sameTimes = snapshot.occurrences.every((item) =>
    formatTime(item.starts_at) ===
      formatTime(snapshot.occurrences[0].starts_at) &&
    formatTime(item.ends_at) === formatTime(snapshot.occurrences[0].ends_at)
  );
  if (!sameTimes) throw new Error("External permit schedule has varying times");
  drawFitted(page, font, formatTime(snapshot.occurrences[0].starts_at), {
    x: 352,
    y: 520,
    width: 86,
    height: 24,
  }, { size: 8, align: "center" });
  drawFitted(page, font, formatTime(snapshot.occurrences[0].ends_at), {
    x: 443,
    y: 520,
    width: 140,
    height: 24,
  }, { size: 8, align: "center" });
  drawFitted(page, bold, snapshot.headcount, {
    x: 217,
    y: 553,
    width: 67,
    height: 21,
  }, { size: 9, align: "center" });
  const admission = snapshot.external_admission_fee_centavos === 0
    ? "No admission fee"
    : formatMoney(snapshot.external_admission_fee_centavos!, true);
  drawFitted(
    page,
    font,
    admission,
    { x: 392, y: 553, width: 191, height: 21 },
    { size: 8, field: "admission_fee" },
  );
  drawImage(page, await embedImage(document, signatures[0]), {
    x: 400,
    y: 617,
    width: 135,
    height: 26,
  });
  drawFitted(page, bold, formatMoney(snapshot.total_amount_centavos), {
    x: 135,
    y: 681,
    width: 100,
    height: 18,
  }, { size: 8.5 });
  check(page, bold, 314, 681, 13, 18);
  drawImage(page, await embedImage(document, signatures[1]), {
    x: 217,
    y: 704,
    width: 191,
    height: 24,
  });
  drawImage(page, await embedImage(document, signatures[2]), {
    x: 171,
    y: 752,
    width: 248,
    height: 27,
  });
}

export async function renderPermit(
  template: Uint8Array,
  snapshot: PermitSnapshot,
  signatures: Uint8Array[],
) {
  const document = await PDFDocument.load(template, { updateMetadata: false });
  if (document.getPageCount() !== 1) {
    throw new Error("Official permit template must have exactly one page");
  }
  const page = document.getPage(0);
  const media = page.getMediaBox();
  const crop = page.getCropBox();
  if (
    Math.abs(page.getWidth() - 595.2756) > 0.2 ||
    Math.abs(page.getHeight() - 841.8898) > 0.2 ||
    Math.abs(media.width - 595.2756) > 0.2 ||
    Math.abs(media.height - 841.8898) > 0.2 ||
    Math.abs(crop.width - 595.2756) > 0.2 ||
    Math.abs(crop.height - 841.8898) > 0.2 ||
    page.getRotation().angle !== 0
  ) {
    throw new Error("Official permit template dimensions or rotation changed");
  }
  if (snapshot.template_kind === "internal") {
    await renderInternal(document, snapshot, signatures);
  } else await renderExternal(document, snapshot, signatures);
  document.setProducer("SmartReserve official permit generator");
  return document.save({ useObjectStreams: false });
}
