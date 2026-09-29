import { buildFcmMessage } from "./contract.ts";
import { sendFcmMessage } from "./fcm.ts";
import { assertEquals } from "jsr:@std/assert@1";

async function serviceAccountJson(): Promise<string> {
  const { privateKey } = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", privateKey));
  const base64 = btoa(String.fromCharCode(...der));
  return JSON.stringify({
    client_email: "push@test-project.iam.gserviceaccount.com",
    private_key: `-----BEGIN PRIVATE KEY-----\n${base64}\n-----END PRIVATE KEY-----\n`,
  });
}

Deno.test("posts the FCM v1 body with the top-level message wrapper", async () => {
  const requests: { url: string; headers: Headers; body: string }[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    requests.push({ url, headers: new Headers(init?.headers), body: String(init?.body) });
    if (url === "https://oauth2.googleapis.com/token") {
      return Promise.resolve(Response.json({ access_token: "access-1", expires_in: 3600 }));
    }
    return Promise.resolve(Response.json({ name: "projects/test-project/messages/1" }));
  };
  try {
    const message = buildFcmMessage({
      id: "d1",
      notification_id: "n1",
      recipient_id: "u1",
      attempt_count: 1,
      kind: "reservation_submitted",
      title: "Submitted",
      body: "Your request was submitted.",
      request_id: "r1",
      tokens: ["tok-a"],
    }, "tok-a");
    const result = await sendFcmMessage({
      projectId: "test-project",
      serviceAccountJson: await serviceAccountJson(),
      message,
      timeoutMs: 5000,
    });

    assertEquals(result, { ok: true });
    const send = requests.find((r) => r.url.startsWith("https://fcm.googleapis.com/"))!;
    assertEquals(send.url, "https://fcm.googleapis.com/v1/projects/test-project/messages:send");
    assertEquals(send.headers.get("Authorization"), "Bearer access-1");
    const body = JSON.parse(send.body);
    // FCM rejects a request whose token/notification sit at the top level.
    assertEquals(Object.keys(body), ["message"]);
    assertEquals(body.message.token, "tok-a");
    assertEquals(body.message.notification.title, "Submitted");
  } finally {
    globalThis.fetch = realFetch;
  }
});
