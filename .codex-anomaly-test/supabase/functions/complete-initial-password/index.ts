import { createClient } from "jsr:@supabase/supabase-js@2";
import { classifyPasswordUpdateFailure } from "./contract.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  Response.json(body, {
    status,
    headers: { ...corsHeaders, "Cache-Control": "no-store" },
  });

const passwordError = (password: string) => {
  if (password.length < 10) return "Use at least 10 characters.";
  if (!/[A-Z]/.test(password)) return "Add at least one uppercase letter.";
  if (!/[a-z]/.test(password)) return "Add at least one lowercase letter.";
  if (!/[0-9]/.test(password)) return "Add at least one number.";
  return null;
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json(
      { code: "method_not_allowed", error: "Method not allowed" },
      405,
    );
  }

  const authorization = request.headers.get("Authorization") ?? "";
  const client = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
  });
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: userData, error: userError } = await client.auth.getUser();
  if (userError || !userData.user) {
    return json({ code: "unauthorized", error: "Unauthorized" }, 401);
  }

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch (_) {
    return json({
      code: "invalid_json",
      error: "Request body must be valid JSON.",
    }, 400);
  }

  const password = typeof body.password === "string" ? body.password : "";
  const validationError = passwordError(password);
  if (validationError) {
    return json({ code: "weak_password", error: validationError }, 400);
  }

  const { data: profile, error: profileError } = await client
    .from("profiles")
    .select("id,must_change_password,account_status")
    .eq("id", userData.user.id)
    .single();
  if (profileError || !profile) {
    return json(
      { code: "profile_not_found", error: "Profile not found." },
      404,
    );
  }
  if (profile.must_change_password !== true) {
    return json({
      code: "password_change_not_required",
      error: "This account does not require a temporary password change.",
    }, 409);
  }
  if (profile.account_status !== "active") {
    return json({
      code: "inactive_account",
      error: "Only active accounts can change temporary credentials.",
    }, 403);
  }

  const { error: passwordUpdateError } = await admin.auth.admin.updateUserById(
    userData.user.id,
    { password },
  );
  if (passwordUpdateError) {
    console.error("complete-initial-password auth update failed", {
      code: passwordUpdateError.code,
      status: passwordUpdateError.status,
    });
    const failure = classifyPasswordUpdateFailure(passwordUpdateError);
    return json({ code: failure.code, error: failure.error }, failure.status);
  }

  const { data: updatedProfile, error: rpcError } = await client.rpc(
    "complete_initial_password_change",
  );
  if (rpcError) {
    console.error("complete-initial-password profile update failed", rpcError);
    return json({
      code: "profile_update_failed",
      error:
        "Password changed, but the account flag could not be cleared. Contact an Internal Admin.",
    }, 500);
  }

  return json({ profile: updatedProfile });
});
