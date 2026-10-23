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
- Transcripts: system messages carry prompt sections and tool declarations,
  with replay helpers (`Transcript`).
- Tool-argument validation and coercion against JSON Schema (`Validation`).
- Reasoning/thinking levels, effort, and adaptive thinking where supported.
- Usage and per-model cost calculation (`Usage` / `UsageCost` / `Pricing`).
- Prompt-cache retention control for Anthropic.
- API-key and OAuth authentication with an on-disk credential store.
- Retry with exponential backoff and `Retry-After` / `x-should-retry` support.
- Cooperative cancellation via `AbortHandle`, with reasons and listeners.
- Request/response/event hooks for observability.
- Client identity: `User-Agent` and provider attribution headers.
- A scripted faux provider for tests.
- Moonshot REST endpoints beyond chat: models, balance, files, token
  estimation, signature verification, web search/fetch, and batches via
  `Rest::Client` (`Models#client`).

## Requirements

- Crystal `>= 1.21.0`
- The `typebox` shard (`github: shpeckman/typebox`), installed by `shards install`

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
  [LLM::AI::UserMessage.new("Say hello in one sentence.", Time.utc)] of LLM::AI::Message,
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

| Provider id   | Display name     | Models                                                                                                                                                                                               |
|---------------|------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `faux`        | Faux (in-memory) | `faux-chat`, `faux-error`                                                                                                                                                                            |
| `deepseek`    | DeepSeek         | `deepseek-flash`, `deepseek-v4-pro`                                                                                                                                                                  |
| `deepseek-anthropic` | DeepSeek (Anthropic API) | Same DeepSeek models over DeepSeek's Anthropic-compatible endpoint                                                                                                                      |
| `deepseek-responses` | DeepSeek (Responses API) | Same DeepSeek models over DeepSeek's OpenAI Responses-compatible endpoint                                                                                                              |
| `anthropic`   | Anthropic        | `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`, `claude-opus-4-8`, `claude-opus-4-7`, `claude-opus-4-6`, `claude-opus-4-5`, `claude-sonnet-4-6`, `claude-sonnet-4-5`, `claude-haiku-4-5` |
| `kimi-coding` | Kimi For Coding  | `kimi-for-coding`, `kimi-for-coding-highspeed`                                                                                                                                                       |
| `moonshot`    | Moonshot         | `kimi-k3`, `kimi-k2.7-code`, `kimi-k2.7-code-highspeed`, `kimi-k2.6`                                                                                                                                 |
| `moonshot-anthropic` | Moonshot (Anthropic API) | Same Kimi models over Moonshot's Anthropic-compatible endpoint                                                                                                                        |
| `moonshot-responses` | Moonshot (Responses API) | `kimi-k3` over Moonshot's Responses endpoint                                                                                                                                          |

The three Moonshot providers share the `MOONSHOT_API_KEY` credential and
differ only in wire protocol: OpenAI chat completions, Anthropic messages,
and the Responses API. The three DeepSeek providers likewise share
`DEEPSEEK_API_KEY` across the same three wire protocols.

DeepSeek thinking effort is controlled with `thinking_level`: levels map to
DeepSeek's `low`/`high`/`max` efforts (`medium`→`high`, `xhigh`→`high`), and
enabling thinking without a level defaults to `high`. Note that DeepSeek
bills peak hours (01:00–04:00 and 06:00–10:00 UTC on weekdays, excluding
Chinese public holidays) at twice the off-peak rates; the cost data in
`src/llm-ai/data/deepseek*.json` reflects the off-peak rates.

Model metadata (context window, max tokens, pricing, and per-model
compatibility flags) is data-driven and loaded from
`src/llm-ai/data/*.json`.

## Authentication

Each provider supports API-key auth via an environment variable, and
credentials can also be stored on disk. The resolution order is: explicit
override → stored credential → environment.

| Provider      | Environment variable(s)                                              |
|---------------|----------------------------------------------------------------------|
| `deepseek`    | `DEEPSEEK_API_KEY`                                                   |
| `anthropic`   | `ANTHROPIC_API_KEY`, `ANTHROPIC_OAUTH_TOKEN`, `ANTHROPIC_AUTH_TOKEN` |
| `kimi-coding` | `KIMI_API_KEY`                                                       |
| `moonshot`    | `MOONSHOT_API_KEY`                                                   |

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

A `ToolResultMessage` also carries `is_error`, `duration_ms`, `details`
(arbitrary JSON for logs or UI), and `usage` (the tool's own usage, if any).
`AssistantMessage`, `ToolResultMessage`, and `SystemMessage` have
`copy_with` for changed copies.

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

### Transcripts

The leading `SystemMessage` of a message list is the system prompt; later
system messages patch it. `content` adds instructions, `sections` replaces
named sections (`nil` removes one), and `tools_added` / `tools_removed`
change the declared tools. `LLM::AI::Transcript` replays them:

```crystal
messages = [
  LLM::AI::Transcript.create_initial_system_message("Be brief.", [weather]).not_nil!,
  LLM::AI::UserMessage.new("hi", Time.utc),
  LLM::AI::SystemMessage.new("", Time.utc, {"skills" => "<skills>…</skills>"} of String => String?),
] of LLM::AI::Message

LLM::AI::Transcript.current_tools(messages)          # => [weather]
LLM::AI::Transcript.current_system_prompt(messages)  # => "Be brief.\n\n<skills>…</skills>"
```

| Function | Meaning |
| --- | --- |
| `create_initial_system_message(prompt, tools)` | The leading system message for a prompt and tools, or `nil` when both are empty. |
| `initial_system_message(messages)` | The leading system message, if any. |
| `current_tools(messages)` | The tools after applying every removal and addition in order. |
| `current_system_message(messages)` | Every system message replayed into one (content joined, sections patched, current tools). |
| `current_system_prompt(messages)` | The replayed prompt text. |
| `tool_state_changes(previous, current)` | `ToolStateChanges` (`tools_added`, `tools_removed`); a changed definition is a removal and an addition. |
| `system_text(message)`, `system_update_text(message)` | A leading prompt, and a later system message as sent mid-conversation. |

The helpers accept any `Array(Message)`, including lists with custom
`Message` subclasses; they only read system messages.

`Models#stream` resolves the transcript's tool declarations for the target
model: models without mid-conversation tool changes get the current tools at
the top level; Kimi-style models (`supports_mid_convo_tool_additions`) keep
later additions in place after the last removal; Anthropic-style models
(`supports_mid_convo_tool_changes`) keep every later change in place.
`Context#tools` counts as a declaration before the first message.

### Tool validation

```crystal
args = LLM::AI::Validation.validate_tool_call(tools, tool_call)    # finds the tool by name
args = LLM::AI::Validation.validate_tool_arguments(tool, tool_call)
```

Validation works on a copy of the arguments: optional properties that are
`null` but do not accept `null` are dropped, primitives are coerced to the
schema's types (`"3"` to `3` for `integer`, `"true"` to `true`, numbers to
strings, union members tried in order), and the result is checked with
`TypeBox::Value.check`. A failure raises `ToolValidationError` listing each
error path and the received arguments; a tool call whose arguments failed to
parse (`arguments_error`) raises before validation.

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

Field                                 | Meaning
--------------------------------------|-------------------------------------------
`max_tokens`                          | Output token cap.
`temperature`                         | Sampling temperature.
`thinking_level` / `thinking_enabled` | Enable reasoning and pick a level.
`effort`                              | Reasoning effort where supported.
`thinking_display`                    | How thinking is surfaced (Anthropic).
`tool_choice`                         | Tool-selection mode.
`headers`                             | Extra request headers.
`cache_retention`                     | `:short`, `:long`, or `:none` (Anthropic).
`max_retries`                         | Retry count for retryable failures.
`timeout_ms`                          | Per-request read timeout.
`user_id`                             | User metadata (Anthropic).
`api_key`                             | API key for this request; overrides stored and ambient credentials. Never serialized.
`session_id`                          | Session identifier for session-aware providers and the faux provider's cache estimate.
`thinking_budgets`                    | Token budgets per thinking level (`"minimal"`, `"low"`, `"medium"`, `"high"`); `xhigh` and `max` use `high`.
`max_retry_delay_ms`                  | Longest server-requested retry wait (default 60 000); `0` removes the cap.
`identity`                            | `ClientIdentity` (below).
`sampling_params`                     | Raw per-request parameters merged last.
`response_format`                     | Response format / JSON schema (compat-gated).
`stop`                                | Stop sequences (compat-gated).
`prediction`                          | Predicted-output content (compat-gated).
`logprobs` / `top_logprobs`           | Token log probabilities (compat-gated); collected on `AssistantMessage#logprobs`.
`prompt_cache_key` / `prompt_cache_options` | Prompt-cache hints (compat-gated).
`safety_identifier`                   | Safety identifier (compat-gated).
`hooks`                               | `StreamHooks` callbacks (below).

## Examples

### Tool calling

```crystal
weather = LLM::AI::Tool.new(
  "get_weather",
  "Get the current weather for a city.",
  JSON.parse(%({"type":"object","properties":{"city":{"type":"string"}},"required":["city"]})),
)

context = LLM::AI::Context.new(
  [LLM::AI::UserMessage.new("What's the weather in Paris?", Time.utc)] of LLM::AI::Message,
  tools: [weather],
)

message = models.chat(model, context)

if call = message.content.select(LLM::AI::ToolCall).first?
  # Execute the tool yourself, then answer with the result.
  result = LLM::AI::ToolResultMessage.new(
    call.id,
    call.name,
    [LLM::AI::TextContent.new("22\u00B0C, sunny")] of LLM::AI::ContentBlock,
    Time.utc,
  )
  followup = LLM::AI::Context.new(
    [
      LLM::AI::UserMessage.new("What's the weather in Paris?", Time.utc),
      message,
      result,
    ] of LLM::AI::Message,
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

`AbortHandle#abort(reason = AbortError.new(...))` or `abort(message)` aborts
once; `aborted?`, `reason`, and `throw_if_aborted` read it, and
`on_abort { |reason| }` registers a listener that runs once at abort and
returns a remover.

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
    on_payload:        ->(payload : JSON::Any, model : LLM::AI::Model) { payload },
    on_response:       ->(status : Int32, headers : HTTP::Headers) { },
    on_event:          ->(event : LLM::AI::StreamEvent) { },
    on_provider_event: ->(data : JSON::Any, model : LLM::AI::Model) { },
  ),
)
```

`on_provider_event` receives each parsed provider stream chunk before
normalization.

### Client identity

```crystal
identity = LLM::AI::ClientIdentity.new(
  user_agent: :short,
  attribution: LLM::AI::ClientAttribution.new("my-app", "https://my-app.example", ["cli-agent"]),
)
options = LLM::AI::StreamOptions.new(identity: identity)
```

Requests send a `User-Agent`: by default
`llm-ai/<version> (<platform>; crystal/<version>; <arch>)`, `llm-ai` with
`:short`, or any `String` given as `user_agent`; `version` replaces the
library version. An `attribution` adds headers only for providers that read
them: OpenRouter (`HTTP-Referer`, `X-OpenRouter-Title`,
`X-OpenRouter-Categories`), NVIDIA NIM (`X-BILLING-INVOKE-ORIGIN`), and
OpenCode (`x-opencode-client`). Explicit `headers` override identity headers.
Anthropic OAuth requests keep the Claude Code identity instead.

### Testing with the scripted faux provider

```crystal
alias Faux = LLM::AI::FauxProvider

faux = Faux.scripted
faux.responses = [
  Faux.assistant_message([Faux.text("Checking."), Faux.tool_call("lookup", {q: "x"}, id: "c1")] of LLM::AI::ContentBlock, stop_reason: :tool_use),
  Faux.assistant_message("Done."),
] of Faux::ResponseStep
faux.append_response { |context, options, state, model| Faux.assistant_message("call #{state.call_count}") }

models = LLM::AI::Models.build
models.register(faux.provider)
message = models.chat(faux.model, context)
```

`Faux.scripted(provider: "faux", models: [ModelDefinition.new("faux-1")],
tokens_per_second: nil, token_size: 3..5)` streams each queued response
block by block in chunks of `token_size` tokens (four characters each),
paced at `tokens_per_second` when given. Responses are `AssistantMessage`s or
factories called with the request; an empty queue answers with an error
message. Usage is estimated from the prompt text, with cache reads against
the previous prompt of the same `session_id`. The handle also has `model`,
`model(id)`, `models`, `state` (`call_count`), `append_responses`, and
`pending_response_count`. Registering it with the id `faux` replaces the
built-in fixed faux provider.

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

DeepSeek's on-disk context cache is automatic. To get cache hits, keep the
system prompt and tool definitions byte-stable across turns; cached input tokens
are reported as `usage.cache_read` and billed at the model's `cache_read` rate.

## Moonshot REST endpoints

`Models#client` returns a `Rest::Client` for a provider's non-streaming REST
API. Auth resolution matches streaming (override → stored credential →
environment). Moonshot registers the full endpoint set; other providers raise
`ModelsError` with kind `"capability"`.

```crystal
client = models.client("moonshot")

models  = client.list_models
balance = client.balance

file = client.upload_file("requests.jsonl", "batch")
batch = client.create_batch(file.id, "12h")
batch = client.get_batch(batch.id)

estimate = client.estimate_tokens(model, context)
check = client.verify_signature(nonce, timestamp_ms, "kimi-k3", signature)

results = client.web_search("crystal programming")
results = client.web_search_pro("crystal", sites: ["crystal-lang.org"])
page = client.fetch("https://crystal-lang.org")

content = client.file_content(file.id)
client.delete_file(file.id)
```

The request signature flow pairs with streaming: send a nonce via
`StreamOptions#headers` (`X-Msh-Request-Nonce`), read the
`Msh-Request-Timestamp` / `Msh-Request-Signature` response headers via the
`on_response` hook, then verify them with `client.verify_signature`.

## Public API reference

- `LLM::AI::Models` — `.build`, `#provider`, `#providers`, `#model`,
  `#models_for`, `#stream`, `#chat`, `#client`, `#store`.
- `LLM::AI::Rest::Client` — `#list_models`, `#balance`, `#upload_file`,
  `#list_files`, `#get_file`, `#delete_file`, `#file_content`,
  `#estimate_tokens`, `#verify_signature`, `#web_search`, `#web_search_pro`,
  `#fetch`, `#create_batch`, `#list_batches`, `#get_batch`, `#cancel_batch`;
  result types under `LLM::AI::Rest` (`Balance`, `RemoteModel`, `FileObject`,
  `TokenEstimate`, `SignatureVerification`, `SearchResult`, `SearchProResult`,
  `FetchResult`, `Batch`, `BatchList`).
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
- `LLM::AI::Transcript`, `LLM::AI::ToolStateChanges`, `LLM::AI::ToolSupport`.
- `LLM::AI::Validation`, `LLM::AI::ToolValidationError`.
- `LLM::AI::ClientIdentity`, `LLM::AI::ClientAttribution`,
  `LLM::AI::UserAgentMode`, `LLM::AI::Identity`, `LLM::AI::VERSION`.
- `LLM::AI::FauxProvider.scripted` and its helpers (`text`, `thinking`,
  `tool_call`, `assistant_message`).
- Auth: `LLM::AI::Auth` (`.resolve`, `.login`, `.logout`),
  `LLM::AI::FileCredentialStore`, `LLM::AI::CredentialStore`,
  `LLM::AI::Auth::Interaction`, `LLM::AI::Auth::CLIInteraction`.

## Development

Run the specs and the linter:

```console
shards install
crystal spec
ameba
```

## License

MIT. See [LICENSE](LICENSE).