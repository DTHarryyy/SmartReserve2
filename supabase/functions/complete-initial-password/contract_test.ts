import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { classifyPasswordUpdateFailure } from "./contract.ts";

Deno.test("maps a reused password to an actionable safe response", () => {
  assertEquals(classifyPasswordUpdateFailure({ code: "same_password" }), {
    code: "same_password",
    error: "Your new password must be different from your current password.",
    status: 422,
  });
});

Deno.test("maps weak, reauthentication, and rate-limit failures", () => {
  assertEquals(
    classifyPasswordUpdateFailure({ code: "weak_password" }).code,
    "weak_password",
  );
  assertEquals(
    classifyPasswordUpdateFailure({ code: "reauthentication_needed" }).status,
    401,
  );
  assertEquals(
    classifyPasswordUpdateFailure({ code: "over_request_rate_limit" }).status,
    429,
  );
});
