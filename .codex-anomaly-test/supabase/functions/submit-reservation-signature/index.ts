import { createClient } from "npm:@supabase/supabase-js@2";
import { PNG } from "npm:pngjs@7.0.0";
import jpeg from "npm:jpeg-js@0.4.4";
import { Buffer } from "node:buffer";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey);
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    // Keep this in step with the headers emitted by Supabase's browser
    // clients.  A missing requested header makes the browser discard an
    // otherwise healthy function response as a network error (status 0).
    "authorization, x-client-info, apikey, content-type, x-supabase-api-version, x-region",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Expose-Headers": "sb-request-id",
  "Vary": "Origin, Access-Control-Request-Headers",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {...corsHeaders, "Content-Type": "application/json"},
  });
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const failure = (code: string, error: string, requestId: string, status: number) =>
  json({code, error, request_id: requestId}, status);

function validImage(bytes: Uint8Array, mimeType: string) {
  if (!bytes.length || bytes.length > 5 * 1024 * 1024) return false;
  const png = bytes.length >= 8 && [137, 80, 78, 71, 13, 10, 26, 10]
    .every((byte, index) => bytes[index] === byte);
  const jpeg = bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 &&
    bytes[2] === 0xff;
  return (mimeType === "image/png" && png) ||
    (mimeType === "image/jpeg" && jpeg);
}

function hasVisibleInk(bytes: Uint8Array, mimeType: string) {
  try {
    const decoded = mimeType === "image/png"
      ? PNG.sync.read(Buffer.from(bytes))
      : jpeg.decode(bytes, {useTArray: true, formatAsRGBA: true});
    for (let offset = 0; offset < decoded.data.length; offset += 4) {
      if (
        decoded.data[offset + 3] > 8 &&
        (decoded.data[offset] < 248 || decoded.data[offset + 1] < 248 ||
          decoded.data[offset + 2] < 248)
      ) {
        return true;
      }
    }
  } catch (_) {
    return false;
  }
  return false;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", {headers: corsHeaders});
  }
  const requestId = crypto.randomUUID();
  if (request.method !== "POST") {
    return failure("method_not_allowed", "POST required.", requestId, 405);
  }

  const authorization = request.headers.get("authorization") ?? "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  const {data: authData, error: authError} = token
    ? await admin.auth.getUser(token)
    : {data: {user: null}, error: new Error("Missing token")};
  const user = authData.user;
  if (authError || !user) {
    return failure("unauthorized", "Please sign in again.", requestId, 401);
  }

  const body = await request.json().catch(() => null);
  if (!body || typeof body !== "object") {
    return failure("invalid_request", "Refresh the reservation and try again.", requestId, 400);
  }
  const values = body as Record<string, unknown>;
  const action = values.action;
  const signatureRequestId = values.signatureRequestId;
  const reservationRequestId = values.requestId;
  if (
    (action !== "prepare" && action !== "complete") ||
    typeof signatureRequestId !== "string" ||
    typeof reservationRequestId !== "string" ||
    !uuidPattern.test(signatureRequestId) || !uuidPattern.test(reservationRequestId)
  ) {
    return failure("invalid_request", "Refresh the reservation and try again.", requestId, 400);
  }

  const {data: signatureRequest, error: lookupError} = await admin
    .from("reservation_signature_requests")
    .select("request_id,requester_id,status")
    .eq("id", signatureRequestId)
    .maybeSingle();
  if (lookupError) {
    console.error("Reservation signature lookup failed", {requestId});
    return failure("server_error", "Signature service is temporarily unavailable. Try again.", requestId, 500);
  }
  if (
    !signatureRequest || signatureRequest.request_id !== reservationRequestId ||
    signatureRequest.requester_id !== user.id || signatureRequest.status !== "requested"
  ) {
    return failure("signature_request_unavailable", "This signature request is no longer available. Refresh and try again.", requestId, 409);
  }

  const mimeType = values.mimeType;
  if (mimeType !== "image/png" && mimeType !== "image/jpeg") {
    return failure("invalid_image", "Choose a PNG or JPEG signature no larger than 5 MB.", requestId, 400);
  }
  if (action === "prepare") {
    const extension = mimeType === "image/png" ? "png" : "jpg";
    const path = `${user.id}/${reservationRequestId}/${crypto.randomUUID()}.${extension}`;
    const {data, error} = await admin.storage
      .from("reservation-signatures")
      .createSignedUploadUrl(path);
    if (error || !data?.token) {
      console.error("Reservation signature upload preparation failed", {requestId});
      return failure("server_error", "Signature service is temporarily unavailable. Try again.", requestId, 500);
    }
    return json({ok: true, path, token: data.token, request_id: requestId});
  }

  const path = values.path;
  const fileName = values.fileName;
  const prefix = `${user.id}/${reservationRequestId}/`;
  if (
    typeof path !== "string" || !path.startsWith(prefix) ||
    path.substring(prefix.length).includes("/") ||
    !path.endsWith(mimeType === "image/png" ? ".png" : ".jpg")
  ) {
    return failure("invalid_request", "Refresh the reservation and try again.", requestId, 400);
  }
  const {data: object, error: downloadError} = await admin.storage
    .from("reservation-signatures")
    .download(path);
  if (downloadError || !object) {
    return failure("signature_upload_missing", "Your signature upload did not finish. Try again.", requestId, 409);
  }
  const source = new Uint8Array(await object.arrayBuffer());
  if (!validImage(source, mimeType)) {
    await admin.storage.from("reservation-signatures").remove([path]);
    return failure("invalid_image", "Choose a PNG or JPEG signature no larger than 5 MB.", requestId, 400);
  }
  if (!hasVisibleInk(source, mimeType)) {
    await admin.storage.from("reservation-signatures").remove([path]);
    return failure(
      "blank_signature",
      "The signature image is blank. Upload an image with a visible signature.",
      requestId,
      400,
    );
  }
  const hash = Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", source.slice().buffer)),
  ).map((byte) => byte.toString(16).padStart(2, "0")).join("");
  const safeFileName = typeof fileName === "string" && fileName.trim()
    ? fileName.trim().slice(0, 255)
    : `signature.${mimeType === "image/png" ? "png" : "jpg"}`;
  const userClient = createClient(url, anonKey, {
    global: {headers: {Authorization: authorization}},
  });
  const {error: submitError} = await userClient.rpc("submit_reservation_signature", {
    p_signature_request_id: signatureRequestId,
    p_storage_path: path,
    p_file_name: safeFileName,
    p_mime_type: mimeType,
    p_byte_size: source.length,
    p_sha256: hash,
  });
  if (submitError) {
    const {error: cleanupError} = await admin.storage
      .from("reservation-signatures")
      .remove([path]);
    console.error("Reservation signature submission failed", {requestId, cleanupFailed: Boolean(cleanupError)});
    return failure(
      cleanupError ? "signature_cleanup_failed" : "signature_submission_failed",
      cleanupError
        ? "Your signature needs support review. Please do not retry yet."
        : "Your signature could not be submitted. Refresh and try again.",
      requestId,
      500,
    );
  }
  return json({ok: true, request_id: requestId});
});
