import {
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  decodeAndValidateImage,
  encodeBase64,
  signatureSlots,
} from "./contract.ts";

Deno.test("official signature slots are scoped to the assigned admin lane", () => {
  assertEquals(signatureSlots.internal_approver.role, "internal_admin");
  assertEquals(signatureSlots.external_recommender.role, "external_admin");
  assertEquals(
    signatureSlots.external_authorized_official.role,
    "external_admin",
  );
});

Deno.test("signature content must match its declared image type", () => {
  const pngHeader = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
  const jpegHeader = new Uint8Array([0xff, 0xd8, 0xff, 0xdb]);
  assertEquals(
    decodeAndValidateImage(encodeBase64(pngHeader), "image/png"),
    pngHeader,
  );
  assertEquals(
    decodeAndValidateImage(encodeBase64(jpegHeader), "image/jpeg"),
    jpegHeader,
  );
  assertThrows(() =>
    decodeAndValidateImage(encodeBase64(jpegHeader), "image/png")
  );
  assertThrows(() => decodeAndValidateImage("not base64!", "image/jpeg"));
});
