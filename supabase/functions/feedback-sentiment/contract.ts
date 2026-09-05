export const allowedSentiments = [
  "positive",
  "neutral",
  "negative",
  "mixed",
  "unknown",
] as const;

export const allowedTopicSentiments = [
  "positive",
  "neutral",
  "negative",
  "mixed",
] as const;

export const allowedTopics = [
  "facility_cleanliness",
  "facility_condition",
  "reservation_process",
  "approval_speed",
  "staff_service",
  "payment_process",
  "equipment_availability",
  "overall_experience",
  "other",
] as const;

export type SentimentLabel = typeof allowedSentiments[number];
export type TopicSentimentLabel = typeof allowedTopicSentiments[number];
export type FeedbackTopic = typeof allowedTopics[number];

export type FeedbackTopicSentiment = {
  topic: FeedbackTopic;
  sentiment: TopicSentimentLabel;
};

export type SentimentResult = {
  sentiment: SentimentLabel;
  confidence: number;
  topics: FeedbackTopicSentiment[];
};

export class SentimentProviderError extends Error {
  constructor(
    readonly code: string,
    message = code,
    readonly retryAfterSeconds?: number,
    readonly terminal = false,
  ) {
    super(message);
    this.name = "SentimentProviderError";
  }
}

const sentimentSet = new Set<string>(allowedSentiments);
const topicSentimentSet = new Set<string>(allowedTopicSentiments);
const topicSet = new Set<string>(allowedTopics);

export const sentimentResponseSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    sentiment: { type: "string", enum: allowedSentiments },
    confidence: { type: "number", minimum: 0, maximum: 1 },
    topics: {
      type: "array",
      minItems: 0,
      maxItems: 3,
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          topic: { type: "string", enum: allowedTopics },
          sentiment: { type: "string", enum: allowedTopicSentiments },
        },
        required: ["topic", "sentiment"],
      },
    },
  },
  required: ["sentiment", "confidence", "topics"],
} as const;

export function sanitizeErrorCode(value: unknown): string {
  const raw = typeof value === "string" && value.trim().length > 0
    ? value.trim().toLowerCase()
    : "analysis_failed";
  const normalized = raw.replace(/[^a-z0-9_]+/g, "_").replace(/^_+|_+$/g, "")
    .slice(0, 80);
  return normalized.length >= 2 ? normalized : "analysis_failed";
}

export function parsePositiveInt(
  value: string | undefined,
  fallback: number,
  min: number,
  max: number,
): number {
  const parsed = Number.parseInt(value ?? "", 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, parsed));
}

export function retryAfterSeconds(header: string | null): number | undefined {
  if (!header) return undefined;
  const seconds = Number.parseInt(header, 10);
  if (Number.isFinite(seconds)) {
    return Math.max(1, Math.min(seconds, 1800));
  }
  const date = Date.parse(header);
  if (!Number.isFinite(date)) return undefined;
  return Math.max(1, Math.min(Math.ceil((date - Date.now()) / 1000), 1800));
}

export function validateSentimentResult(value: unknown): SentimentResult {
  if (!isRecord(value)) {
    throw new SentimentProviderError("malformed_provider_response");
  }

  const keys = Object.keys(value).sort();
  if (keys.join(",") !== "confidence,sentiment,topics") {
    throw new SentimentProviderError("malformed_provider_response");
  }

  if (typeof value.sentiment !== "string" || !sentimentSet.has(value.sentiment)) {
    throw new SentimentProviderError("invalid_sentiment");
  }

  if (typeof value.confidence !== "number" || !Number.isFinite(value.confidence)) {
    throw new SentimentProviderError("invalid_confidence");
  }
  if (value.confidence < 0 || value.confidence > 1) {
    throw new SentimentProviderError("invalid_confidence");
  }

  if (!Array.isArray(value.topics) || value.topics.length > 3) {
    throw new SentimentProviderError("invalid_topics");
  }

  const seen = new Set<string>();
  const topics: FeedbackTopicSentiment[] = [];
  for (const topic of value.topics) {
    if (!isRecord(topic)) {
      throw new SentimentProviderError("invalid_topics");
    }
    const topicKeys = Object.keys(topic).sort();
    if (topicKeys.join(",") !== "sentiment,topic") {
      throw new SentimentProviderError("invalid_topics");
    }
    if (typeof topic.topic !== "string" || !topicSet.has(topic.topic)) {
      throw new SentimentProviderError("invalid_topics");
    }
    if (seen.has(topic.topic)) {
      throw new SentimentProviderError("duplicate_topics");
    }
    if (
      typeof topic.sentiment !== "string" ||
      !topicSentimentSet.has(topic.sentiment)
    ) {
      throw new SentimentProviderError("invalid_topics");
    }
    seen.add(topic.topic);
    topics.push({
      topic: topic.topic as FeedbackTopic,
      sentiment: topic.sentiment as TopicSentimentLabel,
    });
  }

  return {
    sentiment: value.sentiment as SentimentLabel,
    confidence: Math.round(value.confidence * 1000) / 1000,
    topics,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
