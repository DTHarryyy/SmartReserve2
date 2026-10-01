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

// Every signature on both permits uses the same 110×26pt box, centred, so
// they all print at one consistent size.
const signatureWidth = 110;
const signatureHeight = 26;
const signatureBox = (x: number, y: number) => ({
  x,
  y,
  width: signatureWidth,
  height: signatureHeight,
});
// Over the requester line, kept right of the "Requested by:" label (ends
// x≈132.5) and above the printed name (y 540).
const internalRequesterSignatureBox = signatureBox(141, 511);
// The template prints APPROVED / CEO name / title indented at x≈179. The
// whole approval section is right-aligned instead: the printed lines are
// covered and redrawn so the CEO name (the widest line, 258.4pt in Helvetica
// Bold 10) ends on the form's right margin, followed by the internal admin's
// signature, name, role and "Digitally Signed".
const internalApprovalSectionBox = { x: 56, y: 620, width: 490, height: 150 };
const internalApprovalCover = { x: 175, y: 622, width: 270, height: 75 };
const approvalRightX = 538.3;
const approvalSectionX = approvalRightX - 258.42;
// Admin block keeps the template's original indent relative to the CEO name.
const approverBlockX = approvalSectionX + 83.4;
const approverBlockWidth = approvalRightX - approverBlockX;
const internalApproverSignatureBox = signatureBox(approverBlockX, 698);
// The requester's signature is centred just above the "Signature" rule
// (x 336-534, y≈641).
const externalRequesterSignatureBox = signatureBox(380, 614);
// The recommender's signature sits over "DIANA GRACE C. LICOPIT, MBA"
// (x 217-376) in the clear band between the "FACILITY(IES) NOT AVAILABLE"
// checkbox (x 314-324, ends y≈705.2) and the name's caps (from y≈722),
// nudged left of centre so it never touches the checkbox.
const externalRecommenderSignatureBox = {
  x: 229,
  y: 705.4,
  width: signatureWidth,
  height: 16.4,
};
// The authorized official's signature is an admin block like the internal
// one: signature level with "DR. POLICARPIO…" (y 771-780) in the free column
// right of it (x≈430 to the border at 583), then the external admin's name,
// role and "Digitally Signed" down to the bottom rule (y 809.8). The space
// only allows a compact version: a 22pt signature and 10pt line spacing.
const externalAuthorizedBlockBox = { x: 428, y: 756, width: 155, height: 53 };
const externalAdminBlockX = 430;
const externalAuthorizedBlockTop = 757;
const externalHeadcountBox = { x: 145, y: 556, width: 67, height: 14 };
// Blank space under the "Others" row (y 382-446, above TOTAL) where the
// "Others" descriptions are listed, one per line, aligned with the label.
const externalOthersListBox = { x: 18, y: 382, width: 565, height: 64 };
const externalOthersLineY = (line: number) => 383 + line * 12;
const externalOthersMaxLines = 5;

// Internal FACILITIES / EQUIPMENT tables, from the template's own rule lines:
// the check columns span x 57.3-96.6 and x 307.8-347.2, and each row's
// [top, bottom] rule positions are listed so the X is centred in its box.
const internalFacilityCheckColumn = { x: 57, y: 202, width: 40, height: 108 };
const internalEquipmentCheckColumn = { x: 307, y: 202, width: 41, height: 112 };
const internalFacilityRows: Record<string, [number, number]> = {
  audio_visual_main_hall: [202.5, 240.6],
  conference_room: [240.6, 264.7],
  other: [264.7, 309.7],
};
const internalEquipmentRows: Record<string, [number, number]> = {
  sound_system: [202.5, 226.6],
  overhead_projector: [226.6, 250.7],
  lcd_accessories: [250.7, 274.8],
  other: [274.8, 313.0],
};
// "(Please specify):" ends x≈179.9 on baseline ≈294.2 (facility) and x≈430.5
// on baseline ≈304.4 (equipment); the equipment "Others" label ends x≈383.8
// on baseline ≈290.4. Text is kept inside each table's right rule.
const internalFacilityOtherBox = { x: 181, y: 283, width: 105, height: 14 };
const internalEquipmentOtherArea = { x: 386, y: 280, width: 151, height: 30 };
// Overflow line for a long Others list: just under the equipment table
// (bottom rule y 313) and above "Requested Date of Use:" (caps from y≈336).
const internalEquipmentOverflowLine = { x: 307, y: 314, width: 231, height: 13 };

// Boxes below were measured directly off the two approved template PDFs
// (rule-line/checkbox pixel positions decoded from the official artwork,
// cross-checked against the internal template's embedded text layer), not
// eyeballed — see the permit alignment fix for the calibration method.
export const permitOverlayMasks: Record<"internal" | "external", Box[]> = {
  internal: [
    { x: 404, y: 42, width: 134, height: 16 },
    internalFacilityCheckColumn,
    internalFacilityOtherBox,
    internalEquipmentCheckColumn,
    internalEquipmentOtherArea,
    internalEquipmentOverflowLine,
    { x: 57, y: 351, width: 481, height: 13 },
    { x: 57, y: 400, width: 481, height: 41 },
    internalRequesterSignatureBox,
    { x: 60, y: 540, width: 235, height: 10 },
    { x: 134, y: 580, width: 225, height: 13 },
    internalApprovalSectionBox,
  ],
  external: [
    { x: 129, y: 124, width: 293, height: 14 },
    { x: 464, y: 124, width: 115, height: 14 },
    { x: 223, y: 140, width: 357, height: 14 },
    { x: 133, y: 156, width: 447, height: 14 },
    { x: 140, y: 172, width: 440, height: 14 },
    ...[226, 246, 266, 285, 304, 323, 342, 362].map((y) => ({
      x: 18,
      y,
      width: 565,
      height: 19,
    })),
    { x: 409, y: 451, width: 159, height: 18 },
    { x: 15, y: 496, width: 568, height: 18 },
    { x: 180, y: 518, width: 164, height: 22 },
    { x: 397, y: 518, width: 39, height: 22 },
    { x: 499, y: 518, width: 80, height: 22 },
    externalHeadcountBox,
    externalOthersListBox,
    { x: 418, y: 549, width: 161, height: 20 },
    externalRequesterSignatureBox,
    { x: 135, y: 681, width: 100, height: 18 },
    { x: 314, y: 681, width: 13, height: 18 },
    externalRecommenderSignatureBox,
    externalAuthorizedBlockBox,
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
    // Top-down y of a single line's baseline, to sit values on the same
    // baseline as their printed labels instead of the box top.
    baseline?: number;
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
        y: options.baseline !== undefined
          ? page.getHeight() - options.baseline
          : pdfY(page, box) + box.height - size - index * lineHeight,
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

// Lays out the internal "Others (Please specify):" list. One line after the
// colon when it fits; otherwise it starts beside "Others" and continues after
// "(Please specify):", inside the equipment table's right rule; a list too
// long for that continues on one line just under the table. Larger text and
// fewer lines win; item names are kept whole on a line when possible.
function drawEquipmentOthers(page: PDFPage, font: PDFFont, labels: string[]) {
  const text = labels.join(", ");
  if (!text) return;
  type Slot = { x: number; baseline: number; right: number };
  const afterColon: Slot = { x: 432, baseline: 304.4, right: 536 };
  const besideOthers: Slot = { x: 388, baseline: 290.4, right: 536 };
  const belowTable: Slot = { x: 309, baseline: 324, right: 536 };
  const layouts: Slot[][] = [
    [afterColon],
    [besideOthers, afterColon],
    [besideOthers, afterColon, belowTable],
  ];
  // Greedy fill of the slots, breaking between items first and between
  // words only when an item does not fit on a line by itself.
  const fill = (slots: Slot[], size: number) => {
    const tokens = labels.flatMap((label, index) => {
      const words = label.split(" ");
      if (index < labels.length - 1) words[words.length - 1] += ",";
      return words.map((word, wordIndex) => ({
        word,
        itemStart: wordIndex === 0,
      }));
    });
    const lines: string[] = [];
    let index = 0;
    for (const slot of slots) {
      const width = slot.right - slot.x;
      let line = "";
      let lastItemBreak = -1;
      let lineAtItemBreak = "";
      const startIndex = index;
      while (index < tokens.length) {
        const candidate = line ? `${line} ${tokens[index].word}` : tokens[index].word;
        if (font.widthOfTextAtSize(candidate, size) > width) break;
        if (tokens[index].itemStart && line) {
          lastItemBreak = index;
          lineAtItemBreak = line;
        }
        line = candidate;
        index++;
      }
      // Pull a split item back to the next line when an item boundary exists.
      if (
        index < tokens.length && !tokens[index].itemStart &&
        lastItemBreak > startIndex
      ) {
        index = lastItemBreak;
        line = lineAtItemBreak;
      }
      if (!line) return null;
      lines.push(line);
      if (index >= tokens.length) return lines;
    }
    return null;
  };
  const draw = (slots: Slot[], lines: string[], size: number) =>
    lines.forEach((value, line) =>
      drawFitted(page, font, value, {
        x: slots[line].x,
        y: slots[line].baseline - size,
        width: slots[line].right - slots[line].x,
        height: size + 3,
      }, {
        size,
        minSize: size,
        baseline: slots[line].baseline,
        field: "equipment_other",
      })
    );
  for (const minimum of [7, 6.5]) {
    for (const slots of layouts) {
      for (let size = 9; size >= minimum; size -= 0.25) {
        const lines = fill(slots, size);
        if (lines) return draw(slots, lines, size);
      }
    }
  }
  throw new Error("field_does_not_fit:equipment_other");
}

async function renderInternal(
  document: PDFDocument,
  snapshot: PermitSnapshot,
  signatures: Uint8Array[],
  approverName?: string | null,
  facilityAmenities: FacilityAmenity[] = [],
) {
  const page = document.getPage(0);
  pageKinds.set(page, "internal");
  const font = await document.embedFont(StandardFonts.Helvetica);
  const bold = await document.embedFont(StandardFonts.HelveticaBold);
  const italic = await document.embedFont(StandardFonts.HelveticaOblique);
  drawFitted(page, font, formatDate(snapshot.user_signed_at), {
    x: 404,
    y: 42,
    width: 134,
    height: 16,
  }, { size: 9, minSize: 7 });
  // X centred in a table row: Helvetica-Bold cap height is ~0.72em, so the
  // baseline sits 0.36em below the row's vertical centre.
  const checkRow = (column: Box, [top, bottom]: [number, number]) =>
    drawFitted(page, bold, "X", {
      x: column.x,
      y: top,
      width: column.width,
      height: bottom - top,
    }, { size: 10, minSize: 10, align: "center", baseline: (top + bottom) / 2 + 3.6 });
  const facility = snapshot.items.find((item) =>
    item.row_code.startsWith("facility:")
  );
  if (!facility) throw new Error("Facility permit mapping is missing");
  const facilityCode = facility.row_code.split(":")[1];
  const facilityRow = internalFacilityRows[facilityCode];
  if (!facilityRow) {
    throw new Error(`Unsupported internal facility row: ${facilityCode}`);
  }
  checkRow(internalFacilityCheckColumn, facilityRow);
  if (facilityCode === "other") {
    drawFitted(page, font, facility.label, internalFacilityOtherBox, {
      size: 9,
      minSize: 7,
      baseline: 294.2,
      field: "facilities_other",
    });
  }
  // Every equipment item, requested or built into the facility, is either
  // checked in its own row or, when the template has no row for it (an
  // "other" mapping, an exempt comfort amenity or any unknown code), checked
  // under Others and named there. Names already listed are not repeated.
  const equipment = snapshot.items
    .filter((item) => item.row_code.startsWith("equipment:"))
    .map((item) => ({ label: item.label, code: item.row_code.split(":")[1] }));
  const listed = new Set(
    equipment.map((item) => normalizeText(item.label).toLowerCase()),
  );
  for (const amenity of facilityAmenities) {
    const key = normalizeText(amenity.label).toLowerCase();
    if (!key || listed.has(key)) continue;
    listed.add(key);
    equipment.push({
      label: amenity.label,
      code: amenity.rowCode ?? (key === "sound system" ? "sound_system" : "other"),
    });
  }
  const otherEquipment: string[] = [];
  const checkedRows = new Set<string>();
  for (const item of equipment) {
    const code = item.code;
    const row = code !== "other" && internalEquipmentRows[code]
      ? code
      : "other";
    if (row === "other") otherEquipment.push(normalizeText(item.label));
    if (checkedRows.has(row)) continue;
    checkedRows.add(row);
    checkRow(internalEquipmentCheckColumn, internalEquipmentRows[row]);
  }
  if (otherEquipment.length) {
    drawEquipmentOthers(page, font, otherEquipment.filter(Boolean));
  }
  drawFitted(page, font, formatSchedule(snapshot.occurrences), {
    x: 57,
    y: 351,
    width: 481,
    height: 13,
  }, { size: 9.5, minSize: 7.5, field: "requested_date_of_use" });
  drawFitted(page, font, snapshot.purpose, {
    x: 57,
    y: 400,
    width: 481,
    height: 41,
  }, { size: 10, minSize: 7.5, maxLines: 2, field: "purpose" });
  drawFitted(page, font, snapshot.requester_name, {
    x: 60,
    y: 540,
    width: 235,
    height: 10,
  }, { size: 8.5, minSize: 7, align: "center", field: "requester_name" });
  drawFitted(page, font, snapshot.requester_unit, {
    x: 134,
    y: 580,
    width: 225,
    height: 13,
  }, { size: 9, minSize: 7, field: "office_college" });
  drawImage(
    page,
    await embedImage(document, signatures[0]),
    internalRequesterSignatureBox,
  );
  assertInsideOverlayMask(page, internalApprovalCover);
  page.drawRectangle({
    x: internalApprovalCover.x,
    y: pdfY(page, internalApprovalCover),
    width: internalApprovalCover.width,
    height: internalApprovalCover.height,
    color: rgb(1, 1, 1),
  });
  // Box y = template baseline - size, so the redrawn lines keep the
  // template's own sizes and vertical rhythm.
  drawFitted(page, bold, "APPROVED:", {
    x: approvalSectionX,
    y: 625.3,
    width: 120,
    height: 13,
  }, { size: 10.5, minSize: 10.5 });
  drawFitted(page, bold, "DR. POLICARPIO L. MABBORANG, JR., ASEAN ENGR.", {
    x: approvalSectionX,
    y: 666.2,
    width: 259,
    height: 12,
  }, { size: 10, minSize: 10 });
  drawFitted(page, font, "Campus Executive Officer", {
    x: approvalSectionX + 15,
    y: 680.3,
    width: 200,
    height: 13,
  }, { size: 10.5, minSize: 10.5 });
  drawImage(
    page,
    await embedImage(document, signatures[1]),
    internalApproverSignatureBox,
  );
  if (normalizeText(approverName)) {
    drawFitted(page, bold, approverName, {
      x: approverBlockX,
      y: 726,
      width: approverBlockWidth,
      height: 12,
    }, { size: 10, minSize: 7, field: "internal_approver_name" });
  }
  drawFitted(page, font, "Internal Admin", {
    x: approverBlockX,
    y: 739,
    width: approverBlockWidth,
    height: 12,
  }, { size: 10 });
  drawFitted(page, italic, "Digitally Signed", {
    x: approverBlockX,
    y: 752,
    width: approverBlockWidth,
    height: 12,
  }, { size: 9.5 });
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
const externalYs = [226, 246, 266, 285, 304, 323, 342, 362];

async function renderExternal(
  document: PDFDocument,
  snapshot: PermitSnapshot,
  signatures: Uint8Array[],
  options: RenderPermitOptions,
) {
  const page = document.getPage(0);
  pageKinds.set(page, "external");
  const font = await document.embedFont(StandardFonts.TimesRoman);
  const bold = await document.embedFont(StandardFonts.TimesRomanBold);
  const italic = await document.embedFont(StandardFonts.TimesRomanItalic);
  drawFitted(page, font, snapshot.requester_name, {
    x: 129,
    y: 124,
    width: 293,
    height: 14,
  }, { size: 9, minSize: 7, baseline: 135.5, field: "requesting_party" });
  drawFitted(page, font, formatDate(snapshot.user_signed_at), {
    x: 464,
    y: 124,
    width: 115,
    height: 14,
  }, { size: 8.5, minSize: 7, baseline: 135.5 });
  drawFitted(page, font, snapshot.external_company_organization, {
    x: 223,
    y: 140,
    width: 357,
    height: 14,
  }, { size: 9, minSize: 7, baseline: 151.5, field: "company_organization" });
  drawFitted(page, font, snapshot.external_complete_address, {
    x: 133,
    y: 156,
    width: 447,
    height: 14,
  }, { size: 9, minSize: 7, baseline: 167.5, field: "complete_address" });
  drawFitted(page, font, snapshot.external_contact_numbers?.join(" / "), {
    x: 140,
    y: 172,
    width: 440,
    height: 14,
  }, { size: 9, minSize: 7, baseline: 183.5, field: "contact_numbers" });
  const rowCode = (item: PermitItem) =>
    item.row_code.includes(":") ? item.row_code.split(":")[1] : item.row_code;
  const drawAmounts = (item: PermitItem, y: number, height: number) => {
    drawFitted(page, font, formatDuration(item.duration_minutes), {
      x: 228,
      y,
      width: 58,
      height,
    }, { size: 8, minSize: 6.5, align: "center" });
    drawFitted(page, font, formatBasis(item.billing_basis), {
      x: 299,
      y,
      width: 62,
      height,
    }, { size: 8, minSize: 6.5, align: "center" });
    drawFitted(page, font, formatMoney(item.unit_amount_centavos ?? 0), {
      x: 395,
      y,
      width: 50,
      height,
    }, { size: 8, minSize: 6.5, align: "center" });
    drawFitted(page, font, formatMoney(item.line_total_centavos ?? 0), {
      x: 460,
      y,
      width: 112,
      height,
    }, { size: 8, minSize: 6.5, align: "center" });
  };
  // "Others" descriptions go on their own lines below the Others row instead
  // of over the printed "(Please Specify)". A single other keeps its amounts
  // on the Others row; several others each get a line with their amounts.
  // Anything without its own row on the form (an "other" mapping, an exempt
  // comfort amenity or an unknown code) is listed under Others.
  const isOther = (item: PermitItem) =>
    !item.row_code.startsWith("facility:") &&
    (rowCode(item) === "other" || !externalRows.includes(rowCode(item)));
  const others = snapshot.items.filter(isOther);
  if (others.length > externalOthersMaxLines) {
    throw new Error("field_does_not_fit:other_description");
  }
  others.forEach((item, line) => {
    const y = externalOthersLineY(line);
    drawFitted(page, font, item.label, { x: 57, y, width: 165, height: 12 }, {
      size: 8,
      minSize: 6.5,
      field: "other_description",
    });
    if (others.length > 1) drawAmounts(item, y, 12);
  });
  for (const item of snapshot.items) {
    const code = isOther(item) ? "other" : rowCode(item);
    const index = externalRows.indexOf(code);
    if (index < 0) throw new Error(`Unsupported external permit row: ${code}`);
    const y = externalYs[index];
    if (code === "other") {
      if (item === others[0]) check(page, bold, 25, y, 13, 18);
      if (others.length > 1) continue;
    } else {
      check(page, bold, 25, y, 13, 18);
    }
    if (code === "tables_chairs") {
      // Gap between "Tables/ chairs" (ends x≈114) and "(Specify Quantity)".
      drawFitted(page, font, item.requested_quantity, {
        x: 115,
        y,
        width: 26,
        height: 18,
      }, { size: 8.5, minSize: 6.5, align: "center" });
    }
    drawAmounts(item, y, 18);
  }
  drawFitted(page, bold, formatMoney(snapshot.total_amount_centavos), {
    x: 409,
    y: 451,
    width: 159,
    height: 18,
  }, { size: 9, align: "center" });
  drawFitted(page, font, snapshot.purpose, {
    x: 15,
    y: 496,
    width: 568,
    height: 18,
  }, { size: 9, minSize: 7, maxLines: 2, field: "purposes" });
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
  drawFitted(page, font, dates, { x: 180, y: 518, width: 164, height: 22 }, {
    size: 8.5,
    minSize: 6.5,
    baseline: 532,
    field: "inclusive_dates",
  });
  const sameTimes = snapshot.occurrences.every((item) =>
    formatTime(item.starts_at) ===
      formatTime(snapshot.occurrences[0].starts_at) &&
    formatTime(item.ends_at) === formatTime(snapshot.occurrences[0].ends_at)
  );
  if (!sameTimes) throw new Error("External permit schedule has varying times");
  drawFitted(page, font, formatTime(snapshot.occurrences[0].starts_at), {
    x: 397,
    y: 518,
    width: 39,
    height: 22,
  }, { size: 7.5, minSize: 6, align: "center", baseline: 532 });
  drawFitted(page, font, formatTime(snapshot.occurrences[0].ends_at), {
    x: 499,
    y: 518,
    width: 80,
    height: 22,
  }, { size: 8, minSize: 6.5, align: "center", baseline: 532 });
  // After "GUESTS/PARTICIPANTS:" on its own baseline.
  drawFitted(page, bold, snapshot.headcount, externalHeadcountBox, {
    size: 9,
    minSize: 7,
    baseline: 567.5,
  });
  const admission = snapshot.external_admission_fee_centavos === 0
    ? "No admission fee"
    : formatMoney(snapshot.external_admission_fee_centavos!, true);
  drawFitted(
    page,
    font,
    admission,
    { x: 418, y: 549, width: 161, height: 20 },
    { size: 8.5, minSize: 6.5, baseline: 561.5, field: "admission_fee" },
  );
  drawImage(
    page,
    await embedImage(document, signatures[0]),
    externalRequesterSignatureBox,
  );
  drawFitted(page, bold, formatMoney(snapshot.total_amount_centavos), {
    x: 135,
    y: 681,
    width: 100,
    height: 18,
  }, { size: 9, minSize: 7 });
  // Centred in the "FACILITY(IES) AVAILABLE" box (x 314-324, y 681-690).
  drawFitted(page, bold, "X", { x: 314, y: 681, width: 10.5, height: 18 }, {
    size: 10,
    minSize: 10,
    align: "center",
    baseline: 689.2,
  });
  const width = 583 - externalAdminBlockX - 1;
  const adminBlock = async (
    top: number,
    signature: Uint8Array,
    name: string | null | undefined,
  ) => {
    drawImage(page, await embedImage(document, signature), {
      x: externalAdminBlockX,
      y: top,
      width: signatureWidth,
      height: 22,
    });
    const line = (
      lineFont: PDFFont,
      value: string,
      baseline: number,
      size: number,
      field?: string,
    ) =>
      drawFitted(page, lineFont, value, {
        x: externalAdminBlockX,
        y: baseline - size,
        width,
        height: size + 2,
      }, { size, minSize: Math.min(size, 7), baseline, field });
    if (normalizeText(name)) {
      line(bold, normalizeText(name), top + 29, 9, "external_admin_name");
    }
    line(font, "External Admin", top + 39, 9);
    line(italic, "Digitally Signed", top + 48.5, 8.5);
  };
  drawImage(
    page,
    await embedImage(document, signatures[1]),
    externalRecommenderSignatureBox,
  );
  await adminBlock(
    externalAuthorizedBlockTop,
    signatures[2],
    options.externalAuthorizedName,
  );
}

export type FacilityAmenity = { label: string; rowCode?: string | null };

export type RenderPermitOptions = {
  internalApproverName?: string | null;
  externalAuthorizedName?: string | null;
  // The facility's own built-in amenities, listed under B. EQUIPMENT on the
  // internal permit alongside the requested ones.
  facilityAmenities?: FacilityAmenity[];
};

export async function renderPermit(
  template: Uint8Array,
  snapshot: PermitSnapshot,
  signatures: Uint8Array[],
  options: RenderPermitOptions = {},
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
    await renderInternal(
      document,
      snapshot,
      signatures,
      options.internalApproverName,
      options.facilityAmenities,
    );
  } else await renderExternal(document, snapshot, signatures, options);
  document.setProducer("SmartReserve official permit generator");
  return document.save({ useObjectStreams: false });
}
