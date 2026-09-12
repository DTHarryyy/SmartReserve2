import { createClient } from "npm:@supabase/supabase-js@2";
import { PermitSnapshot, sha256, templateHashes } from "./contract.ts";
import { renderPermit } from "./permit_layout.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, serviceKey);
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

async function download(bucket: string, path: string) {
  const { data, error } = await admin.storage.from(bucket).download(path);
  if (error || !data) throw error ?? new Error(`Missing ${bucket} object`);
  return new Uint8Array(await data.arrayBuffer());
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }
  if (request.method !== "POST") return json({ error: "POST required" }, 405);
  const token = request.headers.get("authorization")?.replace(
    /^Bearer\s+/i,
    "",
  );
  if (!token) return json({ error: "Sign in required" }, 401);
  const { data: auth } = await admin.auth.getUser(token);
  if (!auth.user) return json({ error: "Sign in required" }, 401);
  const body = await request.json().catch(() => ({}));
  if (typeof body.requestId !== "string") {
    return json({ error: "Reservation reference required" }, 400);
  }
  if (body.action !== "ensure" && body.action !== "preview") {
    return json({ error: "Unknown action" }, 400);
  }
  let generationStarted = false;
  try {
    const caller = createClient(url, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const { data: readiness, error: readinessError } = await caller.rpc(
      "get_reservation_permit_readiness",
      { p_request_id: body.requestId },
    );
    if (readinessError) throw readinessError;
    if (!readiness?.ready) {
      return json(
        { error: "Permit prerequisites are incomplete", readiness },
        409,
      );
    }
    let permit: Record<string, unknown>;
    if (body.action === "preview") {
      const { data: profile } = await admin.from("profiles").select("role").eq(
        "id",
        auth.user.id,
      ).single();
      if (!["internal_admin", "external_admin"].includes(profile?.role)) {
        return json({ error: "Admin access required" }, 403);
      }
      const { data: material, error: materialError } = await admin.rpc(
        "permit_printable_material",
        { p_request_id: body.requestId },
      );
      if (materialError) throw materialError;
      const { data: userSignature, error: userSignatureError } = await admin
        .from("reservation_user_signatures")
        .select("id,submitted_at").eq("request_id", body.requestId)
        .eq("printable_content_hash", readiness.printable_content_hash).order(
          "submitted_at",
          { ascending: false },
        ).limit(1).single();
      if (userSignatureError) throw userSignatureError;
      const templateKind = readiness.template_kind as "internal" | "external";
      const { data: revisions, error: revisionsError } = await admin.from(
        "permit_official_signature_revisions",
      )
        .select("id,slot").eq("active", true);
      if (revisionsError) throw revisionsError;
      const revision = (slot: string) =>
        revisions.find((item: { slot: string }) => item.slot === slot)?.id;
      permit = {
        permit_number: "PREVIEW",
        version: 0,
        user_signature_id: userSignature.id,
        internal_approver_signature_id: revision("internal_approver"),
        external_recommender_signature_id: revision("external_recommender"),
        external_authorized_signature_id: revision(
          "external_authorized_official",
        ),
        snapshot: {
          ...material,
          template_kind: templateKind,
          template_sha256: templateHashes[templateKind],
          user_signed_at: userSignature.submitted_at,
        },
      };
    } else {
      const { data, error } = await admin.rpc("prepare_reservation_permit", {
        p_request_id: body.requestId,
        p_actor_id: auth.user.id,
      });
      if (error) throw error;
      if (!data) {
        return json(
          { error: "Permit prerequisites are incomplete", readiness },
          409,
        );
      }
      generationStarted = true;
      permit = data as Record<string, unknown>;
      if (permit.generation_status === "ready" && permit.storage_path) {
        return json({ permit });
      }
    }
    const snapshot = permit.snapshot as PermitSnapshot;
    const templateName = snapshot.template_kind === "internal"
      ? "internal Permit.pdf"
      : "External Permit.pdf";
    const template = await Deno.readFile(
      new URL(`./templates/${templateName}`, import.meta.url),
    );
    const actualTemplateHash = await sha256(template);
    if (
      actualTemplateHash !== templateHashes[snapshot.template_kind] ||
      actualTemplateHash !== snapshot.template_sha256
    ) {
      throw new Error("Official permit template integrity check failed");
    }
    const signatures: Uint8Array[] = [];
    const { data: userSignature, error: userError } = await admin.from(
      "reservation_user_signatures",
    )
      .select("storage_path").eq("id", permit.user_signature_id).single();
    if (userError) throw userError;
    signatures.push(
      await download("reservation-signatures", userSignature.storage_path),
    );
    const officialIds = snapshot.template_kind === "internal"
      ? [permit.internal_approver_signature_id]
      : [
        permit.external_recommender_signature_id,
        permit.external_authorized_signature_id,
      ];
    for (const id of officialIds) {
      const { data: revision, error: revisionError } = await admin.from(
        "permit_official_signature_revisions",
      )
        .select("storage_path").eq("id", id).single();
      if (revisionError) throw revisionError;
      signatures.push(
        await download("permit-official-signatures", revision.storage_path),
      );
    }
    const pdf = await renderPermit(template, snapshot, signatures);
    const path =
      `${snapshot.requester_id}/${body.requestId}/${permit.permit_number}-v${permit.version}.pdf`;
    if (body.action === "preview") {
      return new Response(pdf.slice().buffer, {
        headers: {
          ...cors,
          "Content-Type": "application/pdf",
          "Content-Disposition": 'inline; filename="permit-preview.pdf"',
        },
      });
    }
    const { error: uploadError } = await admin.storage.from(
      "reservation-permits",
    ).upload(path, pdf, {
      contentType: "application/pdf",
      upsert: true,
    });
    if (uploadError) throw uploadError;
    const hash = await sha256(pdf);
    const { data: recorded, error: recordError } = await admin.rpc(
      "record_generated_permit",
      {
        p_permit_id: permit.id,
        p_storage_path: path,
        p_sha256: hash,
        p_byte_size: pdf.length,
      },
    );
    if (recordError) throw recordError;
    return json({ permit: recorded });
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    if (generationStarted) {
      try {
        await admin.rpc("mark_permit_generation_failed", {
          p_request_id: body.requestId,
          p_error: detail,
        });
      } catch (_) { /* best-effort status update */ }
    }
    const { data: profile } = await admin.from("profiles").select("role").eq(
      "id",
      auth.user.id,
    ).maybeSingle();
    const adminCaller = ["internal_admin", "external_admin"].includes(
      profile?.role,
    );
    return json({
      error: adminCaller
        ? detail
        : "The permit could not be prepared. The assigned administrator has been notified.",
    }, 409);
  }
});
