import { createClient } from "npm:@supabase/supabase-js@2";
import {
  decodeAndValidateImage,
  encodeBase64,
  type OfficialSignatureSlot,
  signatureSlots,
} from "./contract.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey);
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
};
const response = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

async function authenticatedUser(request: Request) {
  const token = request.headers.get("authorization")?.replace(
    /^Bearer\s+/i,
    "",
  );
  if (!token) return null;
  const { data } = await admin.auth.getUser(token);
  return data.user ?? null;
}

async function authorizedSlot(userId: string, value: unknown) {
  if (typeof value !== "string" || !(value in signatureSlots)) return null;
  const slot = value as OfficialSignatureSlot;
  const { data } = await admin.from("profiles").select("role,account_status")
    .eq("id", userId).maybeSingle();
  return data?.account_status === "active" &&
      data.role === signatureSlots[slot].role
    ? slot
    : null;
}

async function audit(
  userId: string,
  slot: OfficialSignatureSlot,
  action: string,
  revisionId?: string,
) {
  const { data: profile } = await admin.from("profiles").select(
    "full_name,email,role",
  ).eq("id", userId).single();
  const { error } = await admin.from("audit_entries").insert({
    entity_type: "system",
    target_label: "Official permit signature",
    actor_id: userId,
    actor_name: profile?.full_name || profile?.email || userId,
    actor_role: profile?.role || "system",
    action,
    source_type: "permit_official_signature_preview",
    source_id: crypto.randomUUID(),
    details: { slot, revisionId },
  });
  if (error) throw error;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }
  if (request.method !== "POST") {
    return response({ error: "POST required" }, 405);
  }
  const user = await authenticatedUser(request);
  if (!user) return response({ error: "Sign in required" }, 401);
  const body = await request.json().catch(() => ({}));
  const slot = await authorizedSlot(user.id, body.slot);
  if (!slot) {
    return response(
      { error: "You cannot manage that official signature slot" },
      403,
    );
  }

  try {
    if (body.action === "upload") {
      const source = decodeAndValidateImage(body.bytesBase64, body.mimeType);
      const extension = body.mimeType === "image/png" ? "png" : "jpg";
      const path = `${slot}/${crypto.randomUUID()}.${extension}`;
      const hash = Array.from(
        new Uint8Array(
          await crypto.subtle.digest("SHA-256", source.slice().buffer),
        ),
      )
        .map((byte) => byte.toString(16).padStart(2, "0")).join("");
      const { error: uploadError } = await admin.storage.from(
        "permit-official-signatures",
      ).upload(path, source, {
        contentType: body.mimeType,
        upsert: false,
      });
      if (uploadError) throw uploadError;
      const { data: revision, error } = await admin.rpc(
        "record_official_permit_signature",
        {
          p_slot: slot,
          p_storage_path: path,
          p_file_name: String(body.fileName || `signature.${extension}`),
          p_mime_type: body.mimeType,
          p_byte_size: source.length,
          p_sha256: hash,
          p_actor_id: user.id,
        },
      );
      if (error) {
        await admin.storage.from("permit-official-signatures").remove([path]);
        throw error;
      }
      return response({
        ok: true,
        revisionId: revision.id,
        printedIdentity: signatureSlots[slot].printedIdentity,
      });
    }
    if (body.action === "preview") {
      const { data: revision, error } = await admin.from(
        "permit_official_signature_revisions",
      )
        .select("id,storage_path,mime_type,uploaded_at").eq("slot", slot).eq(
          "active",
          true,
        ).maybeSingle();
      if (error) throw error;
      if (!revision) {
        return response({
          active: false,
          printedIdentity: signatureSlots[slot].printedIdentity,
        });
      }
      const { data: object, error: downloadError } = await admin.storage.from(
        "permit-official-signatures",
      ).download(revision.storage_path);
      if (downloadError || !object) {
        throw downloadError ?? new Error("Signature object is unavailable");
      }
      const source = new Uint8Array(await object.arrayBuffer());
      await audit(
        user.id,
        slot,
        "previewed official permit signature",
        revision.id,
      );
      return response({
        active: true,
        revisionId: revision.id,
        mimeType: revision.mime_type,
        uploadedAt: revision.uploaded_at,
        imageBase64: encodeBase64(source),
        printedIdentity: signatureSlots[slot].printedIdentity,
      });
    }
    return response({ error: "Unknown action" }, 400);
  } catch (error) {
    return response({
      error: error instanceof Error
        ? error.message
        : "Permit signature operation failed",
    }, 500);
  }
});
