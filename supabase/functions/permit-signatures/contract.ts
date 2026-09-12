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
      "Internal approving official (fixed name/title on Internal Permit.pdf)",
  },
  external_recommender: {
    role: "external_admin",
    printedIdentity:
      "Business Coordinator (fixed name/title on External Permit.pdf)",
  },
  external_authorized_official: {
    role: "external_admin",
    printedIdentity:
      "President/Authorized Official (fixed name/title on External Permit.pdf)",
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
  const jpeg = source.length >= 3 && source[0] === 0xff && source[1] === 0xd8 &&
    source[2] === 0xff;
  if (
    (mimeType === "image/png" && !png) || (mimeType === "image/jpeg" && !jpeg)
  ) {
    throw new Error("Signature content does not match its declared image type");
  }
  return source;
}
