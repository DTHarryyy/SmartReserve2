export type PasswordUpdateFailure = {
  code: string;
  error: string;
  status: number;
};

export function classifyPasswordUpdateFailure(
  value: unknown,
): PasswordUpdateFailure {
  const error = value && typeof value === "object"
    ? value as Record<string, unknown>
    : {};
  const code = typeof error.code === "string" ? error.code.toLowerCase() : "";
  const message = typeof error.message === "string"
    ? error.message.toLowerCase()
    : "";
  if (
    code === "same_password" || message.includes("same password") ||
    message.includes("different from the old password")
  ) {
    return {
      code: "same_password",
      error: "Your new password must be different from your current password.",
      status: 422,
    };
  }
  if (code === "weak_password" || message.includes("weak password")) {
    return {
      code: "weak_password",
      error:
        "Choose a password with at least 10 characters, uppercase, lowercase, and a number.",
      status: 422,
    };
  }
  if (
    code === "reauthentication_needed" || code === "reauthentication_not_valid"
  ) {
    return {
      code,
      error: "Sign in again before changing your password.",
      status: 401,
    };
  }
  if (code.startsWith("over_") && code.endsWith("_rate_limit")) {
    return {
      code: "rate_limited",
      error: "Too many password attempts. Wait a few minutes and try again.",
      status: 429,
    };
  }
  return {
    code: "password_update_failed",
    error: "Password could not be updated. Try again.",
    status: 500,
  };
}
