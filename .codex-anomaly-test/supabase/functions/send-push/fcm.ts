// FCM HTTP v1 client: mints a short-lived OAuth2 access token from a Google
// service account (RS256-signed JWT bearer flow) and posts messages. This is
// the network/crypto half kept apart from contract.ts so the pure message
// and error-classification logic can be unit tested without a real key.

type ServiceAccount = {
  client_email: string;
  private_key: string;
};

type CachedToken = { accessToken: string; expiresAt: number };

let cachedToken: CachedToken | null = null;

function parseServiceAccount(json: string): ServiceAccount {
  const parsed = JSON.parse(json);
  if (
    typeof parsed?.client_email !== "string" ||
    typeof parsed?.private_key !== "string"
  ) {
    throw new Error("FCM service account JSON is missing client_email/private_key.");
  }
  return { client_email: parsed.client_email, private_key: parsed.private_key };
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlEncodeJson(value: unknown): string {
  return base64UrlEncode(new TextEncoder().encode(JSON.stringify(value)));
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

async function mintAccessToken(serviceAccountJson: string): Promise<CachedToken> {
  const account = parseServiceAccount(serviceAccountJson);
  const key = await importPrivateKey(account.private_key);

  const issuedAt = Math.floor(Date.now() / 1000);
  const expiresAt = issuedAt + 3600;
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: account.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: issuedAt,
    exp: expiresAt,
  };
  const unsigned = `${base64UrlEncodeJson(header)}.${base64UrlEncodeJson(claims)}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const jwt = `${unsigned}.${base64UrlEncode(new Uint8Array(signature))}`;

  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok || typeof payload?.access_token !== "string") {
    throw new Error(`Could not mint an FCM access token (status ${response.status}).`);
  }
  return {
    accessToken: payload.access_token,
    expiresAt: Date.now() + (Number(payload.expires_in) || 3600) * 1000 - 60_000,
  };
}

async function getAccessToken(serviceAccountJson: string): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now()) {
    return cachedToken.accessToken;
  }
  cachedToken = await mintAccessToken(serviceAccountJson);
  return cachedToken.accessToken;
}

export type FcmSendResult = { ok: true } | { ok: false; status: number; body: unknown };

export async function sendFcmMessage(
  options: {
    projectId: string;
    serviceAccountJson: string;
    message: unknown;
    timeoutMs: number;
  },
): Promise<FcmSendResult> {
  const accessToken = await getAccessToken(options.serviceAccountJson);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs);
  try {
    const response = await fetch(
      `https://fcm.googleapis.com/v1/projects/${options.projectId}/messages:send`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(options.message),
        signal: controller.signal,
      },
    );
    if (response.ok) return { ok: true };
    const body = await response.json().catch(() => null);
    return { ok: false, status: response.status, body };
  } finally {
    clearTimeout(timeout);
  }
}
