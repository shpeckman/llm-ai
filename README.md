# llm-ai

A provider-agnostic Crystal client for streaming LLM inference. It gives you one
unified API over several providers, normalizing messages, tools, streaming
events, usage, and cost so you never have to think about the wire format.

All functionality lives under the `LLM::AI` module.

## Features

- One model registry over multiple providers: DeepSeek, Anthropic, Kimi, and
  Moonshot (plus an in-memory `faux` provider for tests).
- Normalized message model: system, user, assistant, and tool-result messages.
- Normalized content blocks: text, thinking/reasoning, images, and tool calls.
- Streaming via a typed event stream (`StreamEvent`) with a terminal
  `Done`/`Error` event.
- Tool calling with JSON-schema definitions and partial-argument streaming.
- Reasoning/thinking levels, effort, and adaptive thinking where supported.
- Usage and per-model cost calculation (`Usage` / `UsageCost` / `Pricing`).
- Prompt-cache retention control for Anthropic.
- API-key and OAuth authentication with an on-disk credential store.
- Retry with exponential backoff and `Retry-After` / `x-should-retry` support.
- Cooperative cancellation via `AbortHandle`.
- Request/response/event hooks for observability.

## Requirements

- Crystal `>= 1.21.0`

## Installation

Add the shard to your `shard.yml`:

```yaml
dependencies:
  llm-ai:
    github: shpeckman/llm-ai
```

Then run `shards install`. In your code:

```crystal
require "llm-ai"
```

`llm-ai` is a library: it defines no `targets` of its own.

## Quick start

```crystal
require "llm-ai"

models = LLM::AI::Models.build
model  = models.model("deepseek", "deepseek-v4-pro")

context = LLM::AI::Context.new(
  [LLM::AI::UserMessage.new("Say hello in one sentence.", Time.utc)],
  system_prompt: "You are a helpful assistant.",
)

message = models.chat(model, context)
puts message.content.select(LLM::AI::TextContent).map(&.text).join
```

To stream instead:

```crystal
stream = models.stream(model, context)
stream.each do |event|
  case event
  when LLM::AI::StreamEvent::TextDelta
    print event.text
  when LLM::AI::StreamEvent::Done
    puts
  end
end
```

## Providers and models

| Provider id | Display name | Models |
|-------------|--------------|--------|
| `faux` | Faux (in-memory) | `faux-chat`, `faux-error` |
| `deepseek` | DeepSeek | `deepseek-flash`, `deepseek-v4-pro` |
| `anthropic` | Anthropic | `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`, `claude-opus-4-8`, `claude-opus-4-7`, `claude-opus-4-6`, `claude-opus-4-5`, `claude-sonnet-4-6`, `claude-sonnet-4-5`, `claude-haiku-4-5` |
| `kimi-coding` | Kimi For Coding | `kimi-for-coding`, `kimi-for-coding-highspeed` |
| `moonshot` | Moonshot | `kimi-k3`, `kimi-k2.7-code`, `kimi-k2.7-code-highspeed`, `kimi-k2.6` |

Model metadata (context window, max tokens, pricing, and per-model
compatibility flags) is data-driven and loaded from
`src/llm/ai/data/*.json`.

## Authentication

Each provider supports API-key auth via an environment variable, and
credentials can also be stored on disk. The resolution order is: explicit
override → stored credential → environment.

| Provider | Environment variable(s) |
|----------|--------------------------|
| `deepseek` | `DEEPSEEK_API_KEY` |
| `anthropic` | `ANTHROPIC_API_KEY`, `ANTHROPIC_OAUTH_TOKEN`, `ANTHROPIC_AUTH_TOKEN` |
| `kimi-coding` | `KIMI_API_KEY` |
| `moonshot` | `MOONSHOT_API_KEY` |

Stored credentials live in `~/.config/pi-ai-cr/auth.json` by default
(`FileCredentialStore`). Log in and out interactively:

```crystal
store       = LLM::AI::FileCredentialStore.new
models      = LLM::AI::Models.build(store)
interaction = LLM::AI::Auth::CLIInteraction.new

LLM::AI::Auth.login(models, "deepseek", :api_key, interaction)
LLM::AI::Auth.logout(models, "deepseek")
```

Anthropic and Kimi also support OAuth subscription login:

```crystal
LLM::AI::Auth.login(models, "anthropic", :oauth, interaction)
LLM::AI::Auth.login(models, "kimi-coding", :oauth, interaction)
```

Anthropic uses a browser redirect (PKCE); Kimi uses device-code flow. You can
supply your own `LLM::AI::Auth::Interaction` to drive these flows
programmatically instead of on a TTY.

## Core concepts

### `Context`

A `Context` is the request: a message list plus optional system prompt and
tools.

```crystal
context = LLM::AI::Context.new(messages, system_prompt: "...", tools: [tool])
```

### Messages

`Message` is a discriminated union on `"role"`:

- `SystemMessage` — system prompt content (with optional named `sections`).
- `UserMessage` — a `String` or an `Array(ContentBlock)`.
- `AssistantMessage` — model output: content blocks plus provider/model,
  `usage`, `stop_reason`, timing, and `end_turn`.
- `ToolResultMessage` — a tool's result, keyed by `tool_call_id`.

`UserMessage` and `SystemMessage` require a `Time` timestamp (serialized as
epoch milliseconds).

### Content blocks

`ContentBlock` is a discriminated union on `"type"`:

- `TextContent` — plain text.
- `ThinkingContent` — reasoning text with an optional signature.
- `ImageContent` — base64 image data plus MIME type.
- `ToolCall` — an id, name, and `JSON::Any` arguments.

### Streaming

`models.stream` returns a `MessageStream`. Each `StreamEvent` carries a
`partial` `AssistantMessage` snapshot. The event lifecycle per block is
`*Start` → `*Delta`* → `*End`; the stream always terminates with exactly one
`Done` or `Error` event.

- `StreamEvent::Start`
- `StreamEvent::TextStart` / `TextDelta` / `TextEnd`
- `StreamEvent::ThinkingStart` / `ThinkingDelta` / `ThinkingEnd`
- `StreamEvent::ToolCallStart` / `ToolCallDelta` / `ToolCallEnd`
- `StreamEvent::Done` (final message, `reason`)
- `StreamEvent::Error` (final message, `reason` is `:error` or `:aborted`)

`MessageStream#result` drains the stream and returns the final
`AssistantMessage`, raising `ModelsError` if the stream failed.

### `StopReason`

`Stop`, `Length`, `ToolUse`, `Error`, `Aborted`, `Deferred`, or `Pending`.

## Options

`StreamOptions` controls a request. All fields are optional.

```crystal
options = LLM::AI::StreamOptions.new(
  max_tokens:      4096,
  temperature:     0.7,
  thinking_level:  "high",
  tool_choice:     "auto",
  cache_retention: :long,
  max_retries:     3,
  timeout_ms:      120_000,
)
```

| Field | Meaning |
|-------|---------|
| `max_tokens` | Output token cap. |
| `temperature` | Sampling temperature. |
| `thinking_level` / `thinking_enabled` | Enable reasoning and pick a level. |
| `effort` | Reasoning effort where supported. |
| `thinking_display` | How thinking is surfaced (Anthropic). |
| `tool_choice` | Tool-selection mode. |
| `headers` | Extra request headers. |
| `cache_retention` | `:short`, `:long`, or `:none` (Anthropic). |
| `max_retries` | Retry count for retryable failures. |
| `timeout_ms` | Per-request read timeout. |
| `user_id` | User metadata (Anthropic). |
| `sampling_params` | Raw per-request parameters merged last. |
| `hooks` | `StreamHooks` callbacks (below). |

## Examples

### Tool calling

```crystal
weather = LLM::AI::Tool.new(
  "get_weather",
  "Get the current weather for a city.",
  JSON.parse(%({"type":"object","properties":{"city":{"type":"string"}},"required":["city"]})),
)

context = LLM::AI::Context.new(
  [LLM::AI::UserMessage.new("What's the weather in Paris?", Time.utc)],
  tools: [weather],
)

message = models.chat(model, context)

if call = message.content.select(LLM::AI::ToolCall).first?
  # Execute the tool yourself, then answer with the result.
  result = LLM::AI::ToolResultMessage.new(
    call.id,
    call.name,
    [LLM::AI::TextContent.new("22\u00B0C, sunny")],
    Time.utc,
  )
  followup = LLM::AI::Context.new(
    [
      LLM::AI::UserMessage.new("What's the weather in Paris?", Time.utc),
      message,
      result,
    ],
    tools: [weather],
  )
  answer = models.chat(model, followup)
  puts answer.content.select(LLM::AI::TextContent).map(&.text).join
end
```

### Thinking / reasoning

```crystal
options = LLM::AI::StreamOptions.new(thinking_level: "high")
stream  = models.stream(model, context, options)
stream.each do |event|
  case event
  when LLM::AI::StreamEvent::ThinkingDelta
    print event.thinking
  when LLM::AI::StreamEvent::TextDelta
    print event.text
  when LLM::AI::StreamEvent::Done
    puts
  end
end
```

### Cancellation

```crystal
abort = LLM::AI::AbortHandle.new

spawn do
  sleep 1.second
  abort.abort
end

stream = models.stream(model, context, LLM::AI::StreamOptions.new, abort)
stream.each do |event|
  # The stream ends with an Error event whose reason is :aborted.
end
```

### Hooks

```crystal
options = LLM::AI::StreamOptions.new(
  hooks: LLM::AI::StreamHooks.new(
    on_payload:  ->(payload : JSON::Any, model : LLM::AI::Model) { payload },
    on_response: ->(status : Int32, headers : HTTP::Headers) { },
    on_event:    ->(event : LLM::AI::StreamEvent) { },
  ),
)
```

### Usage and cost

```crystal
message = models.chat(model, context)
if usage = message.usage
  puts "tokens: #{usage.total_tokens}"
  if cost = usage.cost
    puts "cost: $#{cost.total}"
  end
end
```

## Public API reference

- `LLM::AI::Models` — `.build`, `#provider`, `#providers`, `#model`,
  `#models_for`, `#stream`, `#chat`, `#store`.
- `LLM::AI::MessageStream` — `#each`, `#result`, `#abort`.
- `LLM::AI::Context`, `LLM::AI::Tool`, `LLM::AI::StreamOptions`,
  `LLM::AI::StreamHooks`.
- Messages: `SystemMessage`, `UserMessage`, `AssistantMessage`,
  `ToolResultMessage`.
- Content blocks: `TextContent`, `ThinkingContent`, `ImageContent`,
  `ToolCall`.
- Events: `StreamEvent::Start`, `Text*`, `Thinking*`, `ToolCall*`, `Done`,
  `Error`.
- `LLM::AI::StopReason`, `LLM::AI::Usage`, `LLM::AI::UsageCost`,
  `LLM::AI::Model`, `LLM::AI::Provider`.
- `LLM::AI::AbortHandle`, `LLM::AI::AbortError`, `LLM::AI::ModelsError`.
- `LLM::AI::Pricing.calculate`, `LLM::AI::Transform.normalize`.
- Auth: `LLM::AI::Auth` (`.resolve`, `.login`, `.logout`),
  `LLM::AI::FileCredentialStore`, `LLM::AI::CredentialStore`,
  `LLM::AI::Auth::Interaction`, `LLM::AI::Auth::CLIInteraction`.

## License

MIT. See [LICENSE](LICENSE).
