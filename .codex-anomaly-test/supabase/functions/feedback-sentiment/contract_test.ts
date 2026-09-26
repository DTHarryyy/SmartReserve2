import {
  retryAfterSeconds,
  sanitizeErrorCode,
  validateSentimentResult,
} from "./contract.ts";
import {
  assertEquals,
  assertThrows,
} from "jsr:@std/assert@1";

Deno.test("validates a positive English sentiment response", () => {
  const result = validateSentimentResult({
    sentiment: "positive",
    confidence: 0.94321,
    topics: [
      { topic: "facility_cleanliness", sentiment: "positive" },
      { topic: "staff_service", sentiment: "positive" },
    ],
  });

  assertEquals(result.sentiment, "positive");
  assertEquals(result.confidence, 0.943);
  assertEquals(result.topics.length, 2);
});

Deno.test("accepts Tagalog and Taglish classifications through the same contract", () => {
  const result = validateSentimentResult({
    sentiment: "negative",
    confidence: 0.87,
    topics: [{ topic: "approval_speed", sentiment: "negative" }],
  });

  assertEquals(result.sentiment, "negative");
  assertEquals(result.topics[0].topic, "approval_speed");
});

Deno.test("rejects extra top-level properties", () => {
  assertThrows(() =>
    validateSentimentResult({
      sentiment: "positive",
      confidence: 0.9,
      topics: [],
      explanation: "not allowed",
    })
  );
});

Deno.test("rejects invalid sentiment labels", () => {
  assertThrows(() =>
    validateSentimentResult({
      sentiment: "angry",
      confidence: 0.8,
      topics: [],
    })
  );
});

Deno.test("rejects invalid confidence values", () => {
  assertThrows(() =>
    validateSentimentResult({
      sentiment: "unknown",
      confidence: 1.2,
      topics: [],
    })
  );
});

Deno.test("rejects duplicate or excessive topics", () => {
  assertThrows(() =>
    validateSentimentResult({
      sentiment: "mixed",
      confidence: 0.72,
      topics: [
        { topic: "staff_service", sentiment: "positive" },
        { topic: "staff_service", sentiment: "negative" },
      ],
    })
  );

  assertThrows(() =>
    validateSentimentResult({
      sentiment: "mixed",
      confidence: 0.72,
      topics: [
        { topic: "facility_cleanliness", sentiment: "negative" },
        { topic: "facility_condition", sentiment: "negative" },
        { topic: "staff_service", sentiment: "positive" },
        { topic: "payment_process", sentiment: "negative" },
      ],
    })
  );
});

Deno.test("normalizes operational error codes", () => {
  assertEquals(sanitizeErrorCode("Provider Timeout!"), "provider_timeout");
  assertEquals(sanitizeErrorCode("x"), "analysis_failed");
});

Deno.test("parses retry-after headers defensively", () => {
  assertEquals(retryAfterSeconds("90"), 90);
  assertEquals(retryAfterSeconds("99999"), 1800);
  assertEquals(retryAfterSeconds("not a date"), undefined);
});
