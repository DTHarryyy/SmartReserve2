import {
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { PNG } from "npm:pngjs@7.0.0";
import jpeg from "npm:jpeg-js@0.4.4";
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
  const image = new PNG({ width: 3, height: 2 });
  image.data.fill(255);
  image.data[0] = 0;
  image.data[1] = 0;
  image.data[2] = 0;
  const png = new Uint8Array(PNG.sync.write(image));
  const jpegBytes = jpeg.encode({
    width: image.width,
    height: image.height,
    data: image.data,
  }, 95).data;
  const jpegImage = new Uint8Array(jpegBytes);
  assertEquals(decodeAndValidateImage(encodeBase64(png), "image/png"), png);
  assertEquals(
    decodeAndValidateImage(encodeBase64(jpegImage), "image/jpeg"),
    jpegImage,
  );
  assertThrows(() =>
    decodeAndValidateImage(encodeBase64(jpegImage), "image/png")
  );
  assertThrows(() => decodeAndValidateImage("not base64!", "image/jpeg"));
});

Deno.test("blank official signatures are rejected before they become active", () => {
  const image = new PNG({ width: 3, height: 2 });
  image.data.fill(255);
  assertThrows(
    () => decodeAndValidateImage(
      encodeBase64(new Uint8Array(PNG.sync.write(image))),
      "image/png",
    ),
    Error,
    "blank",
  );
});
