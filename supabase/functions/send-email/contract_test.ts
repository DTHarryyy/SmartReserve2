import {
  escapeHtml,
  isDeliverableAddress,
  isPermanentSmtpError,
  parseLeasedJobs,
  renderEmail,
  smtpErrorCode,
  subjectFor,
} from "./contract.ts";
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";

const job = {
  id: "d1",
  notification_id: "n1",
  recipient_id: "u1",
  attempt_count: 1,
  kind: "reservation_approved",
  title: "Reservation approved",
  body: "Gym on Friday was approved.\n\nPay the down payment within 24 hours.",
  request_id: "r1",
  email: "renter@example.test",
  full_name: "Jamie Cruz",
};

Deno.test("parses leased rows and drops ones without ids", () => {
  const rows = parseLeasedJobs({
    rows: [
      { ...job, email: "  renter@example.test " },
      { notification_id: "n2" },
      "junk",
    ],
  });
  assertEquals(rows.length, 1);
  assertEquals(rows[0].email, "renter@example.test");
  assertEquals(parseLeasedJobs(null), []);
});

Deno.test("renders a branded email with the notification content", () => {
  const email = renderEmail(job, "https://smartreserve.example.test");
  assertEquals(email.to, "renter@example.test");
  assertEquals(email.subject, "SmartReserve: Reservation approved");
  assert(email.html.includes("Hi Jamie Cruz,"));
  assert(email.html.includes("Gym on Friday was approved."));
  assert(email.html.includes('href="https://smartreserve.example.test"'));
  assert(email.text.includes("Pay the down payment within 24 hours."));
  assert(
    email.text.includes("Open SmartReserve: https://smartreserve.example.test"),
  );
});

Deno.test("omits the button when no app URL is configured", () => {
  const email = renderEmail(job, "");
  assertFalse(email.html.includes("Open SmartReserve</a>"));
  assertFalse(email.text.includes("Open SmartReserve:"));
});

Deno.test("escapes notification text so it cannot inject markup", () => {
  const email = renderEmail(
    { ...job, title: "<script>x</script>", body: 'a "b" & <i>c</i>' },
    "",
  );
  assertFalse(email.html.includes("<script>"));
  assert(email.html.includes("&lt;script&gt;"));
  assertEquals(escapeHtml(`'"&<>`), "&#39;&quot;&amp;&lt;&gt;");
});

Deno.test("subjects stay on one line", () => {
  assertEquals(
    subjectFor({ ...job, title: "Line one\r\nBcc: someone@example.test" }),
    "SmartReserve: Line one Bcc: someone@example.test",
  );
  assertEquals(
    subjectFor({ ...job, title: "  " }),
    "SmartReserve: New notification",
  );
});

Deno.test("validates addresses", () => {
  assert(isDeliverableAddress("a@b.co"));
  assertFalse(isDeliverableAddress("not-an-email"));
  assertFalse(isDeliverableAddress(""));
});

Deno.test("classifies SMTP failures", () => {
  assert(isPermanentSmtpError({ responseCode: 550 }));
  assertFalse(
    isPermanentSmtpError({ responseCode: 535 }),
    "bad credentials retry",
  );
  assertFalse(isPermanentSmtpError({ responseCode: 421 }));
  assertFalse(isPermanentSmtpError(new Error("ETIMEDOUT")));
  assertEquals(smtpErrorCode({ responseCode: 550 }), "smtp_550");
  assertEquals(smtpErrorCode({ code: "ECONNECTION" }), "econnection");
});
