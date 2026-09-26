import {
  buildFcmMessage,
  classifyFcmError,
  parseLeasedJobs,
  sanitizeErrorCode,
} from "./contract.ts";
import { assertEquals } from "jsr:@std/assert@1";

const job = {
  id: "d1",
  notification_id: "n1",
  recipient_id: "u1",
  attempt_count: 1,
  kind: "reservation_submitted",
  title: "Submitted",
  body: "Your request was submitted.",
  request_id: "r1",
  tokens: ["tok-a"],
};

Deno.test("builds an FCM message with the deep-link data payload", () => {
  const { message } = buildFcmMessage(job, "tok-a");
  assertEquals(message.token, "tok-a");
  assertEquals(message.notification, { title: "Submitted", body: "Your request was submitted." });
  assertEquals(message.data, {
    kind: "reservation_submitted",
    notification_id: "n1",
    request_id: "r1",
  });
});

Deno.test("sends with high priority on the heads-up Android channel", () => {
  const { message } = buildFcmMessage(job, "tok-a");
  assertEquals(message.android, {
    priority: "HIGH",
    ttl: "3600s",
    notification: { channel_id: "smartreserve_alerts" },
  });
  assertEquals(message.webpush.headers, { Urgency: "high", TTL: "3600" });
  assertEquals(message.apns.headers, { "apns-priority": "10" });
});

Deno.test("omits request_id from the data payload when the notification has none", () => {
  const { message } = buildFcmMessage({ ...job, request_id: null }, "tok-a");
  assertEquals(message.data, { kind: "reservation_submitted", notification_id: "n1" });
});

Deno.test("classifies UNREGISTERED as a dead token", () => {
  const outcome = classifyFcmError(404, {
    error: {
      status: "NOT_FOUND",
      details: [{
        "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
        errorCode: "UNREGISTERED",
      }],
    },
  });
  assertEquals(outcome, "dead_token");
});

Deno.test("classifies a malformed token argument as a dead token", () => {
  const outcome = classifyFcmError(400, {
    error: {
      status: "INVALID_ARGUMENT",
      details: [{
        "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
        errorCode: "INVALID_ARGUMENT",
      }],
    },
  });
  assertEquals(outcome, "dead_token");
});

Deno.test("classifies a 500 as retryable", () => {
  assertEquals(classifyFcmError(500, { error: { status: "INTERNAL" } }), "retry");
});

Deno.test("classifies a 429 as retryable", () => {
  assertEquals(classifyFcmError(429, { error: { status: "RESOURCE_EXHAUSTED" } }), "retry");
});

Deno.test("classifies an unrecognized 401 as fatal, not a dead token or a retry", () => {
  assertEquals(classifyFcmError(401, { error: { status: "UNAUTHENTICATED" } }), "fatal");
});

Deno.test("sanitizeErrorCode normalizes free-form messages into a short code", () => {
  assertEquals(sanitizeErrorCode("Could not reach FCM!!"), "could_not_reach_fcm");
  assertEquals(sanitizeErrorCode(""), "send_failed");
  assertEquals(sanitizeErrorCode(undefined), "send_failed");
});

Deno.test("parseLeasedJobs drops rows with no tokens and coerces field types", () => {
  const jobs = parseLeasedJobs({
    rows: [
      {
        id: "d1",
        notification_id: "n1",
        recipient_id: "u1",
        attempt_count: "3",
        kind: "reservation_submitted",
        title: "Submitted",
        body: "Body",
        request_id: "r1",
        tokens: ["tok-a", "tok-b"],
      },
      {
        id: "d2",
        notification_id: "n2",
        recipient_id: "u2",
        attempt_count: 1,
        kind: "reservation_reminder",
        title: "Reminder",
        body: "Body",
        request_id: null,
        tokens: [],
      },
    ],
  });
  assertEquals(jobs.length, 1);
  assertEquals(jobs[0].id, "d1");
  assertEquals(jobs[0].attempt_count, 3);
  assertEquals(jobs[0].tokens, ["tok-a", "tok-b"]);
});

Deno.test("parseLeasedJobs handles a missing or malformed rows field", () => {
  assertEquals(parseLeasedJobs({}), []);
  assertEquals(parseLeasedJobs(null), []);
  assertEquals(parseLeasedJobs({ rows: "not-an-array" }), []);
});
