// OpenAI chat-completions adapter.
//
// Adapted from feedback-sentiment/groq.ts, which already talks to an
// OpenAI-compatible endpoint: the request body, the choices[0].message
// parsing, the AbortController timeout and the HTTP error taxonomy all carry
// over unchanged. Two deliberate differences: `reasoning_effort` is dropped
// (it is a Groq/gpt-oss option, not a standard chat parameter), and tool
// calling is genuinely new -- the sentiment worker only ever used structured
// output.
//
// The provider lives behind this one module so swapping it back to Groq, or
// on to another vendor, does not touch the tool layer or the rule layer.

import {
  AssistantProviderError,
  retryAfterSeconds,
} from "./contract.ts";

const openAiUrl = "https://api.openai.com/v1/chat/completions";

export type ChatMessage =
  | { role: "system" | "user" | "assistant"; content: string }
  | {
    role: "assistant";
    content: string | null;
    tool_calls: ProviderToolCall[];
  }
  | { role: "tool"; tool_call_id: string; content: string };

export type ProviderToolCall = {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
};

export type ToolDefinition = {
  type: "function";
  function: {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  };
};

export type CompletionResult = {
  content: string;
  toolCalls: ProviderToolCall[];
  finishReason: string;
  usage: { inputTokens: number; outputTokens: number };
};

export type CompletionOptions = {
  apiKey: string;
  model: string;
  timeoutMs: number;
  maxCompletionTokens: number;
  messages: ChatMessage[];
  tools?: ToolDefinition[];
};

export async function complete(
  options: CompletionOptions,
): Promise<CompletionResult> {
  if (!options.apiKey) {
    throw new AssistantProviderError(
      "configuration_error",
      "OPENAI_API_KEY is missing.",
      undefined,
      true,
    );
  }
  if (!options.model) {
    throw new AssistantProviderError(
      "configuration_error",
      "ASSISTANT_MODEL is missing.",
      undefined,
      true,
    );
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs);

  let response: Response;
  try {
    response = await fetch(openAiUrl, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "Authorization": `Bearer ${options.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: options.model,
        messages: options.messages,
        ...(options.tools && options.tools.length > 0
          ? { tools: options.tools, tool_choice: "auto" }
          : {}),
        temperature: 0,
        max_completion_tokens: options.maxCompletionTokens,
        stream: false,
      }),
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      throw new AssistantProviderError("provider_timeout");
    }
    throw new AssistantProviderError("provider_network_error");
  } finally {
    clearTimeout(timeout);
  }

  if (!response.ok) throw httpError(response);

  let payload: unknown;
  try {
    payload = await response.json();
  } catch (_) {
    throw new AssistantProviderError("malformed_provider_response");
  }

  return parseCompletion(payload);
}

export function parseCompletion(payload: unknown): CompletionResult {
  if (!isRecord(payload)) {
    throw new AssistantProviderError("malformed_provider_response");
  }
  const choices = payload.choices;
  if (!Array.isArray(choices) || choices.length === 0) {
    throw new AssistantProviderError("malformed_provider_response");
  }
  const first = choices[0];
  if (!isRecord(first) || !isRecord(first.message)) {
    throw new AssistantProviderError("malformed_provider_response");
  }

  const message = first.message;
  const content = typeof message.content === "string" ? message.content : "";
  const rawCalls = Array.isArray(message.tool_calls) ? message.tool_calls : [];

  const toolCalls: ProviderToolCall[] = [];
  for (const call of rawCalls) {
    if (!isRecord(call) || !isRecord(call.function)) continue;
    const name = call.function.name;
    const args = call.function.arguments;
    if (typeof name !== "string") continue;
    toolCalls.push({
      id: typeof call.id === "string" ? call.id : crypto.randomUUID(),
      type: "function",
      function: {
        name,
        arguments: typeof args === "string" ? args : JSON.stringify(args ?? {}),
      },
    });
  }

  const usage = isRecord(payload.usage) ? payload.usage : {};
  return {
    content,
    toolCalls,
    finishReason: typeof first.finish_reason === "string"
      ? first.finish_reason
      : "stop",
    usage: {
      inputTokens: numberOr(usage.prompt_tokens, 0),
      outputTokens: numberOr(usage.completion_tokens, 0),
    },
  };
}

function httpError(response: Response): AssistantProviderError {
  if (response.status === 429) {
    return new AssistantProviderError(
      "rate_limited",
      "The assistant service is busy.",
      retryAfterSeconds(response.headers.get("Retry-After")),
    );
  }
  if (response.status === 401 || response.status === 403) {
    // Terminal: retrying a bad key only burns latency.
    return new AssistantProviderError(
      "provider_auth_error",
      "Assistant provider authentication failed.",
      undefined,
      true,
    );
  }
  if (response.status === 408) {
    return new AssistantProviderError("provider_timeout");
  }
  if (response.status >= 500) {
    return new AssistantProviderError("provider_unavailable");
  }
  if (response.status >= 400) {
    return new AssistantProviderError(
      "provider_request_error",
      "The assistant provider rejected the request.",
      undefined,
      true,
    );
  }
  return new AssistantProviderError("provider_error");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}
