import { PNG } from "npm:pngjs@7.0.0";
import jpegCodec from "npm:jpeg-js@0.4.4";
import { Buffer } from "node:buffer";

export type OfficialSignatureSlot =
  | "internal_approver"
  | "external_recommender"
  | "external_authorized_official";

export const signatureSlots: Record<OfficialSignatureSlot, {
  role: "internal_admin" | "external_admin";
  printedIdentity: string;
}> = {
  internal_approver: {
    role: "internal_admin",
    printedIdentity:
      "DR. POLICARPIO L. MABBORANG, JR., ASEAN ENGR. — Campus Executive Officer",
  },
  external_recommender: {
    role: "external_admin",
    printedIdentity: "DIANA GRACE C. LICOPIT, MBA — Business Coordinator",
  },
  external_authorized_official: {
    role: "external_admin",
    printedIdentity:
      "DR. POLICARPIO L. MABBORANG, JR., ASEAN ENGR. — President/Authorized Official",
  },
};

export const encodeBase64 = (bytes: Uint8Array) => {
  let output = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    output += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(output);
};

export function decodeAndValidateImage(value: unknown, mimeType: unknown) {
  if (
    typeof value !== "string" ||
    !["image/png", "image/jpeg"].includes(String(mimeType))
  ) {
    throw new Error("A PNG or JPEG signature is required");
  }
  let source: Uint8Array;
  try {
    const binary = atob(value);
    source = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch (_) {
    throw new Error("The signature image is not valid base64 data");
  }
  if (!source.length || source.length > 5 * 1024 * 1024) {
    throw new Error("Signature must be 5 MB or smaller");
  }
  const png = source.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10]
    .every((byte, index) => source[index] === byte);
  const isJpeg = source.length >= 3 && source[0] === 0xff && source[1] === 0xd8 &&
    source[2] === 0xff;
  if (
    (mimeType === "image/png" && !png) ||
    (mimeType === "image/jpeg" && !isJpeg)
  ) {
    throw new Error("Signature content does not match its declared image type");
  }
  try {
    const decoded = png
      ? PNG.sync.read(Buffer.from(source))
      : jpegCodec.decode(source, { useTArray: true, formatAsRGBA: true });
    let hasVisibleInk = false;
    for (let offset = 0; offset < decoded.data.length; offset += 4) {
      if (
        decoded.data[offset + 3] > 8 &&
        (decoded.data[offset] < 248 || decoded.data[offset + 1] < 248 ||
          decoded.data[offset + 2] < 248)
      ) {
        hasVisibleInk = true;
        break;
      }
    }
    if (!hasVisibleInk) {
      throw new Error("The signature image is blank. Upload an image with a visible signature.");
    }
  } catch (error) {
    if (error instanceof Error && error.message.includes("blank")) throw error;
    throw new Error("The signature image could not be read.");
  }
  return source;
}
