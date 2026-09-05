import { createClient } from "jsr:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const inviteRedirectTo = Deno.env.get("INVITE_REDIRECT_TO") ?? "";
const recoveryRedirectTo = Deno.env.get("RECOVERY_REDIRECT_TO") ??
  inviteRedirectTo;

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

type Profile = Record<string, unknown> & {
  id: string;
  email: string;
  full_name: string;
  role: string;
  account_status: string;
};

const accountJson = (
  profile: Profile,
  authUser: Record<string, unknown> | undefined,
  actorId: string,
) => ({
  id: profile.id,
  email: profile.email,
  full_name: profile.full_name || profile.email,
  role: profile.role,
  unit: profile.unit ?? "",
  campus_id: profile.campus_id ?? "",
  verification_status: profile.verification_status ?? "none",
  account_status: profile.account_status,
  created_at: profile.created_at,
  last_sign_in_at: authUser?.last_sign_in_at ?? null,
  invitation_sent_at: profile.invitation_sent_at ?? authUser?.invited_at ??
    null,
  email_confirmed_at: authUser?.email_confirmed_at ?? null,
  suspension_reason: profile.suspension_reason ?? null,
  suspended_until: profile.suspended_until ?? null,
  organization_slot_id: profile.organization_slot_id ?? null,
  organization_slot_label: profile.organization_slot_label ?? null,
  organization_unit_id: profile.organization_unit_id ?? null,
  organization_unit_name: profile.organization_unit_name ?? null,
  organization_unit_code: profile.organization_unit_code ?? null,
  organization_unit_type: profile.organization_unit_type ?? null,
  organization_unit_booking_audience:
    profile.organization_unit_booking_audience ?? null,
  account_access_type: profile.account_access_type ?? "legacy_unassigned",
  must_change_password: profile.must_change_password ?? false,
  password_issued_at: profile.password_issued_at ?? null,
  is_self: profile.id === actorId,
  activity_metrics_available: false,
});

const profileColumns = [
  `
  id,
  email,
  full_name,
  role,
  unit,
  campus_id,
  campus_claim,
  verification_status,
  account_status,
  account_access_type,
  must_change_password,
  password_issued_at,
  created_at,
  suspension_reason,
  suspended_until,
  invitation_sent_at,
  organization_slot_id,
  organization_account_slots(
    id,
    label,
    unit_id,
    organizational_units(id,name,code,unit_type,booking_audience,requires_representative)
  )
  `,
].join(",");

const normalizeProfile = (profile: Record<string, unknown>): Profile => {
  const slot = profile.organization_account_slots as
    | Record<string, unknown>
    | null
    | undefined;
  const unit = slot?.organizational_units as
    | Record<string, unknown>
    | null
    | undefined;
  return {
    ...profile,
    organization_slot_label: slot?.label ?? null,
    organization_unit_id: unit?.id ?? slot?.unit_id ?? null,
    organization_unit_name: unit?.name ?? null,
    organization_unit_code: unit?.code ?? null,
    organization_unit_type: unit?.unit_type ?? null,
    organization_unit_booking_audience: unit?.booking_audience ?? null,
  } as Profile;
};

const temporaryPassword = () => {
  const upper = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  const lower = "abcdefghijkmnopqrstuvwxyz";
  const digits = "23456789";
  const symbols = "!@#$%*-_";
  const all = `${upper}${lower}${digits}${symbols}`;
  const random = (alphabet: string) =>
    alphabet[crypto.getRandomValues(new Uint8Array(1))[0] % alphabet.length];
  const characters = [
    random(upper),
    random(lower),
    random(digits),
    random(symbols),
    ...Array.from({ length: 16 }, () => random(all)),
  ];
  for (let index = characters.length - 1; index > 0; index--) {
    const swapIndex = crypto.getRandomValues(new Uint8Array(1))[0] %
      (index + 1);
    [characters[index], characters[swapIndex]] = [
      characters[swapIndex],
      characters[index],
    ];
  }
  return characters.join("");
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
  const { data: userData, error: userError } = await client.auth.getUser();
  if (userError || !userData.user) {
    return json({ code: "unauthorized", error: "Unauthorized" }, 401);
  }

  await client.rpc("normalize_my_expired_suspension");
  const { data: actor, error: actorError } = await client
    .from("profiles")
    .select("role,account_status")
    .eq("id", userData.user.id)
    .single();
  if (
    actorError || actor.role !== "internal_admin" ||
    actor.account_status !== "active"
  ) {
    return json({
      code: "forbidden",
      error: "Only an active internal administrator can manage users.",
    }, 403);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  await admin.rpc("normalize_expired_suspensions");

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch (_) {
    return json({
      code: "invalid_json",
      error: "Request body must be valid JSON.",
    }, 400);
  }

  const action = typeof body.action === "string" ? body.action : "";
  const targetId = typeof body.target_id === "string" ? body.target_id : "";
  const requestId = crypto.randomUUID();

  const loadAuthUsers = async () => {
    const users: Record<string, unknown>[] = [];
    for (let page = 1;; page++) {
      const { data, error } = await admin.auth.admin.listUsers({
        page,
        perPage: 1000,
      });
      if (error) throw error;
      users.push(...(data.users as unknown as Record<string, unknown>[]));
      if (data.users.length < 1000) break;
    }
    return users;
  };

  const loadAccount = async (id: string) => {
    const { data: profile, error: profileError } = await admin
      .from("profiles")
      .select(profileColumns)
      .eq("id", id)
      .single();
    if (profileError) throw profileError;
    const { data: authData, error: authError } = await admin.auth.admin
      .getUserById(id);
    if (authError) throw authError;
    return accountJson(
      normalizeProfile(profile as unknown as Record<string, unknown>),
      authData.user as unknown as Record<string, unknown>,
      userData.user.id,
    );
  };

  const loadTarget = async () => {
    if (!targetId) throw new Error("target_required");
    const { data, error } = await admin
      .from("profiles")
      .select(profileColumns)
      .eq("id", targetId)
      .single();
    if (error) throw error;
    return normalizeProfile(data as unknown as Record<string, unknown>);
  };

  const recordEvent = async (
    target: Profile | null,
    eventAction: string,
    reason: string | null,
    beforeValues: Record<string, unknown>,
    afterValues: Record<string, unknown>,
    targetEmail?: string,
  ) => {
    const { error } = await admin.from("account_admin_events").insert({
      actor_id: userData.user.id,
      target_id: target?.id ?? null,
      target_email: targetEmail ?? target?.email ?? "",
      action: eventAction,
      reason,
      before_values: beforeValues,
      after_values: afterValues,
    });
    if (error) throw error;
  };

  try {
    if (action === "list") {
      const profiles: Profile[] = [];
      for (let from = 0;; from += 1000) {
        const { data, error } = await admin
          .from("profiles")
          .select(profileColumns)
          .order("created_at", { ascending: false })
          .range(from, from + 999);
        if (error) throw error;
        profiles.push(...(data as unknown as Profile[]));
        if (data.length < 1000) break;
      }
      const authUsers = await loadAuthUsers();
      const byId = new Map(authUsers.map((user) => [user.id as string, user]));
      return json({
        accounts: profiles.map((profile) =>
          accountJson(
            normalizeProfile(profile as unknown as Record<string, unknown>),
            byId.get(profile.id),
            userData.user.id,
          )
        ),
      });
    }

    if (action === "create_administrator" || action === "create_admin") {
      const email = typeof body.email === "string"
        ? body.email.trim().toLowerCase()
        : "";
      const role = typeof body.role === "string" ? body.role : "";
      const note = typeof body.note === "string" ? body.note.trim() : "";
      if (
        !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) ||
        !["internal_admin", "external_admin"].includes(role)
      ) {
        return json({
          code: "invalid_administrator",
          error: "Enter a valid email address and administrator role.",
        }, 400);
      }
      const { data: duplicate } = await admin.from("profiles").select("id")
        .ilike("email", email).maybeSingle();
      if (duplicate) {
        return json({
          code: "email_exists",
          error: "That address already has an account.",
        }, 409);
      }

      const password = temporaryPassword();
      const { data: created, error: createError } = await admin.auth.admin
        .createUser({
          email,
          password,
          email_confirm: true,
          user_metadata: {
            created_by_administrator: true,
            administrator_note: note,
            administrator_role: role,
          },
        });
      if (createError || !created.user) {
        throw createError ??
          new Error("Administrator account creation failed");
      }

      const { data: profile, error: profileError } = await admin
        .from("profiles")
        .update({
          role,
          account_status: "active",
          account_access_type: "administrator",
          must_change_password: false,
          password_issued_at: null,
          onboarding_complete: true,
          invitation_sent_at: null,
          organization_slot_id: null,
          campus_claim: null,
          verification_status: "none",
          unit: "",
        })
        .eq("id", created.user.id)
        .select(profileColumns)
        .single();
      if (profileError) {
        await admin.auth.admin.deleteUser(created.user.id);
        throw profileError;
      }
      const createdProfile = normalizeProfile(
        profile as unknown as Record<string, unknown>,
      );
      await recordEvent(
        createdProfile,
        "create_administrator",
        note || null,
        {},
        createdProfile,
      );
      return json({
        account: accountJson(
          createdProfile,
          created.user as unknown as Record<string, unknown>,
          userData.user.id,
        ),
        temporary_password: password,
      });
    }

    if (action === "create_organization_representative") {
      const email = typeof body.email === "string"
        ? body.email.trim().toLowerCase()
        : "";
      const fullName = typeof body.full_name === "string"
        ? body.full_name.trim()
        : "";
      const organizationSlotId = typeof body.organization_slot_id === "string"
        ? body.organization_slot_id.trim()
        : "";

      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
        return json({
          code: "invalid_email",
          error: "Enter a valid email address.",
        }, 400);
      }
      if (fullName.length < 2) {
        return json({
          code: "invalid_full_name",
          error: "Enter the representative's full name.",
        }, 400);
      }
      if (!organizationSlotId) {
        return json({
          code: "slot_required",
          error: "Choose a vacant organization account slot.",
        }, 400);
      }

      const { data: duplicate } = await admin.from("profiles").select("id")
        .ilike("email", email).maybeSingle();
      if (duplicate) {
        return json({
          code: "email_exists",
          error: "That address already has an account.",
        }, 409);
      }

      const password = temporaryPassword();
      const { data: invitation, error: invitationError } = await admin.auth
        .admin.createUser({
          email,
          password,
          email_confirm: true,
          user_metadata: {
            full_name: fullName,
            created_by_administrator: true,
            organization_slot_id: organizationSlotId,
            organization_account_policy: "representative",
          },
        });
      if (invitationError || !invitation.user) {
        throw invitationError ??
          new Error("Organization representative account creation failed");
      }

      const { data: profile, error: profileError } = await admin.rpc(
        "provision_organization_representative_profile",
        {
          p_actor: userData.user.id,
          p_profile_id: invitation.user.id,
          p_full_name: fullName,
          p_slot_id: organizationSlotId,
        },
      );
      if (profileError) {
        await admin.auth.admin.deleteUser(invitation.user.id);
        throw profileError;
      }
      const createdProfile = normalizeProfile(
        profile as unknown as Record<string, unknown>,
      );
      return json({
        account: accountJson(
          createdProfile,
          invitation.user as unknown as Record<string, unknown>,
          userData.user.id,
        ),
        temporary_password: password,
      });
    }

    if (action === "invite") {
      const email = typeof body.email === "string"
        ? body.email.trim().toLowerCase()
        : "";
      const role = typeof body.role === "string" ? body.role : "";
      const note = typeof body.note === "string" ? body.note.trim() : "";
      if (
        !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) ||
        !["internal_admin", "external_admin"].includes(role)
      ) {
        return json({
          code: "invalid_invitation",
          error:
            "Prototype invitations are limited to administrator accounts. Create organization representatives with direct credentials.",
        }, 400);
      }

      const { data: duplicate } = await admin.from("profiles").select("id")
        .ilike("email", email).maybeSingle();
      if (duplicate) {
        return json({
          code: "email_exists",
          error: "That address already has an account.",
        }, 409);
      }

      const { data: invitation, error: invitationError } = await admin.auth
        .admin.inviteUserByEmail(email, {
          data: {
            invitation_note: note,
            invited_role: role,
          },
          redirectTo: inviteRedirectTo || undefined,
        });
      if (invitationError || !invitation.user) {
        throw invitationError ?? new Error("Invitation failed");
      }

      const sentAt = new Date().toISOString();
      const { data: profile, error: profileError } = await admin
        .from("profiles")
        .update({
          role,
          account_status: "invited",
          account_access_type: "administrator",
          onboarding_complete: true,
          invitation_sent_at: sentAt,
          organization_slot_id: null,
          campus_claim: null,
          verification_status: "none",
          unit: "",
        })
        .eq("id", invitation.user.id)
        .select(profileColumns)
        .single();
      if (profileError) {
        await admin.auth.admin.deleteUser(invitation.user.id);
        throw profileError;
      }
      const createdProfile = normalizeProfile(
        profile as unknown as Record<string, unknown>,
      );
      await recordEvent(
        createdProfile,
        "invite",
        note || null,
        {},
        createdProfile,
      );
      return json({
        account: accountJson(
          createdProfile,
          invitation.user as unknown as Record<string, unknown>,
          userData.user.id,
        ),
      });
    }

    if (action === "resend_invite") {
      const target = await loadTarget();
      const { data: authData, error: authError } = await admin.auth.admin
        .getUserById(target.id);
      if (authError) throw authError;
      if (
        target.account_status !== "invited" || authData.user.email_confirmed_at
      ) {
        return json({
          code: "invite_not_pending",
          error: "This invitation is no longer pending.",
        }, 409);
      }
      const { error: inviteError } = await admin.auth.admin.inviteUserByEmail(
        target.email,
        {
          data: authData.user.user_metadata,
          redirectTo: inviteRedirectTo || undefined,
        },
      );
      if (inviteError) throw inviteError;
      const sentAt = new Date().toISOString();
      const { error: updateError } = await admin.from("profiles").update({
        invitation_sent_at: sentAt,
      }).eq("id", target.id);
      if (updateError) throw updateError;
      await recordEvent(target, "resend_invite", null, target, {
        ...target,
        invitation_sent_at: sentAt,
      });
      return json({ account: await loadAccount(target.id) });
    }

    if (action === "revoke_invite") {
      const target = await loadTarget();
      const { data: authData, error: authError } = await admin.auth.admin
        .getUserById(target.id);
      if (authError) throw authError;
      if (
        target.account_status !== "invited" || authData.user.email_confirmed_at
      ) {
        return json({
          code: "invite_not_pending",
          error: "This invitation is no longer pending.",
        }, 409);
      }
      const { error: deleteError } = await admin.auth.admin.deleteUser(
        target.id,
      );
      if (deleteError) throw deleteError;
      await recordEvent(null, "revoke_invite", null, target, {}, target.email);
      return json({ removed_id: target.id });
    }

    if (
      ["change_role", "suspend", "lift_suspension", "request_reverification"]
        .includes(action)
    ) {
      const requestedRole = typeof body.role === "string" ? body.role : null;
      if (
        action === "change_role" &&
        (requestedRole === null ||
          !["user", "internal_admin", "external_admin"].includes(
            requestedRole,
          ))
      ) {
        return json({
          code: "invalid_role",
          error:
            "That's not a role SmartReserve recognizes. Choose User, Internal admin, or External admin.",
        }, 400);
      }
      const { error } = await admin.rpc("admin_manage_account", {
        p_actor: userData.user.id,
        p_target: targetId,
        p_action: action,
        p_role: requestedRole,
        p_reason: typeof body.reason === "string" ? body.reason.trim() : null,
        p_suspended_until:
          typeof body.suspended_until === "string" && body.suspended_until
            ? body.suspended_until
            : null,
      });
      if (error) throw error;
      return json({ account: await loadAccount(targetId) });
    }

    if (action === "reset_organization_representative_password") {
      const target = await loadTarget();
      if (
        target.account_access_type !== "organization_representative" ||
        target.account_status !== "active"
      ) {
        return json({
          code: "invalid_target",
          error: "Choose an active organization representative account.",
        }, 400);
      }

      const password = temporaryPassword();
      const { error: passwordError } = await admin.auth.admin.updateUserById(
        target.id,
        { password },
      );
      if (passwordError) throw passwordError;

      const { data: profile, error: profileError } = await admin.rpc(
        "record_organization_representative_password_reset",
        {
          p_actor: userData.user.id,
          p_profile_id: target.id,
        },
      );
      if (profileError) throw profileError;

      const updatedProfile = normalizeProfile(
        profile as unknown as Record<string, unknown>,
      );
      return json({
        account: accountJson(updatedProfile, undefined, userData.user.id),
        temporary_password: password,
      });
    }

    if (action === "send_password_reset") {
      const target = await loadTarget();
      if (target.account_status === "invited") {
        return json({
          code: "invite_pending",
          error: "Resend the invitation instead.",
        }, 409);
      }
      const { error } = await admin.auth.resetPasswordForEmail(target.email, {
        redirectTo: recoveryRedirectTo || undefined,
      });
      if (error) throw error;
      await recordEvent(target, "send_password_reset", null, target, target);
      return json({ account: await loadAccount(target.id) });
    }

    return json(
      { code: "invalid_action", error: "Invalid account action." },
      400,
    );
  } catch (error) {
    const errorRecord = error && typeof error === "object"
      ? error as Record<string, unknown>
      : null;
    const message = error instanceof Error
      ? error.message
      : typeof errorRecord?.message === "string"
      ? errorRecord.message
      : String(error);
    const lower = message.toLowerCase();
    if (lower.includes("not found") || lower.includes("target_required")) {
      return json({ code: "not_found", error: "Account not found." }, 404);
    }
    if (
      lower.includes("last active") || lower.includes("cannot change") ||
      lower.includes("cannot suspend")
    ) {
      const guardrailMessage = lower.includes("own role")
        ? "You cannot change your own role."
        : lower.includes("own account")
        ? "You cannot suspend your own account."
        : lower.includes("demoted")
        ? "The last active internal administrator cannot be demoted."
        : "The last active internal administrator cannot be suspended.";
      return json({ code: "guardrail", error: guardrailMessage }, 409);
    }
    if (lower.includes("already") || lower.includes("registered")) {
      return json({
        code: "conflict",
        error: "That email address already has an account.",
      }, 409);
    }
    if (lower.includes("invalid role")) {
      return json({
        code: "invalid_role",
        error:
          "That's not a role SmartReserve recognizes. Choose User, Internal admin, or External admin.",
      }, 400);
    }
    if (lower.includes("reason is required")) {
      return json({
        code: "reason_required",
        error: "Enter a reason before saving this action.",
      }, 400);
    }
    if (lower.includes("future lift")) {
      return json({
        code: "invalid_lift_date",
        error: "Choose a future suspension lift date.",
      }, 400);
    }
    if (lower.includes("rate limit") || lower.includes("too many requests")) {
      return json({
        code: "rate_limited",
        error: "Too many requests. Wait a moment and try again.",
      }, 429);
    }
    console.error("manage-users failed", { requestId, action, error });
    return json({
      code: "server_error",
      error: "User management is temporarily unavailable. Try again.",
      request_id: requestId,
    }, 500);
  }
});
