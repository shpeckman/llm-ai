# AGENTS.md

## Overview

`llm-ai` is a provider-agnostic Crystal library for streaming LLM inference.
It exposes one `LLM::AI` API over multiple providers (DeepSeek, Anthropic,
Kimi, Moonshot, and an in-memory `faux` provider), normalizing messages,
tools, streaming events, usage, and cost behind a single interface.

This is a **library, not an application**: `shard.yml` defines no `targets`,
and there is no `bin/`. The public contract is the `LLM::AI` module.

## Repository layout

All code lives under `src/llm-ai/`, next to the entry point `src/llm-ai.cr`. Crystal resolves `require "llm-ai/x"` to `src/llm-ai/x.cr`. Paths follow the shard name, not the module path.

```
src/llm-ai.cr                     Entry point: requires the tree, opens LLM::AI
src/llm-ai/types.cr               Core types: messages, content blocks, stream
                                  events, Model, StreamOptions, Usage, enums
src/llm-ai/models.cr              Models registry: build, lookup, stream/chat
src/llm-ai/model_data.cr          Parses src/llm-ai/data/*.json into Model[]
src/llm-ai/pricing.cr             Cost calculation from usage + model rates
src/llm-ai/http.cr                HTTP request + retry/backoff + abort support
src/llm-ai/sse.cr                 Server-sent-events reader
src/llm-ai/partial_json.cr        Completes partial JSON for streaming tool args
src/llm-ai/abort.cr               AbortHandle for cooperative cancellation
src/llm-ai/api/transform_messages.cr  Normalize a Context for a target model
src/llm-ai/api/simple_options.cr      Resolve StreamOptions + thinking levels
src/llm-ai/api/jsonify.cr         Serialize JSON::Any into a JSON::Builder
src/llm-ai/api/openai_completions.cr  OpenAI Chat Completions wire adapter
src/llm-ai/api/anthropic_messages.cr  Anthropic Messages wire adapter
src/llm-ai/auth.cr                Auth resolution + login/logout
src/llm-ai/auth/credential_store.cr   CredentialStore / FileCredentialStore
src/llm-ai/auth/oauth.cr          OAuth primitives (PKCE, callback server, events)
src/llm-ai/auth/anthropic_oauth.cr    Anthropic OAuth (browser/PKCE) + refresh
src/llm-ai/auth/kimi_oauth.cr         Kimi OAuth (device code) + refresh
src/llm-ai/providers/*.cr         One Provider definition per provider
src/llm-ai/data/*.json            Model metadata: pricing, windows, compat flags
spec/                             Crystal specs (one file per unit)
.ameba.yml                        Ameba linter config (disabled rules)
```

## Build / test / spec

There are no build targets. Install dependencies and run the specs and linter:

```console
shards install
crystal spec
ameba
```

`shard.lock`, `lib/`, `.shards/`, `bin/`, and `docs/` are gitignored. The
specs use a local `HTTP::Server` (see `spec/spec_helper.cr` for `MockApi` and
`ScriptedApi`) and never hit the network. `ameba` reads `.ameba.yml`; three
rules are intentionally disabled there — `Naming/QueryBoolMethods` (would
rename `Bool` getters to `?` and break the public API), `Lint/NotNil`
(`not_nil!` is used intentionally), and `Metrics/CyclomaticComplexity`.

## Code standards

- Every Crystal file opens with a single comment naming its path, e.g.
  `# src/llm-ai/models.cr`. No other comments in code.
- Compiler-friendly, performance-focused, idiomatic Crystal.
- Data-driven design: model metadata, pricing, and compatibility flags live in
  `src/llm-ai/data/*.json` and are parsed by `ModelData`, not hard-coded.
- The usage-facing API must be ergonomic: favor named arguments with sensible
  defaults and a small number of entry points.
- Prevent shotgun surgery: a behavior change should touch one cohesive spot,
  not be scattered across adapters.
- Never use `out` as an identifier — it is a reserved keyword.
- Never edit the `version` field in `shard.yml`.
- Match existing naming and structural idioms rather than importing new
  conventions.
- Keep `README.md` (usage and public API) and this file in sync with the code.

## Conventions specific to this codebase

- A provider registers a single `Provider` value (id, name, base URL, headers,
  auth, models, and a `stream` proc) in `Models.build`
  (`src/llm-ai/models.cr`).
- Two wire adapters exist: `Api::OpenAICompletions` (DeepSeek, Kimi, Moonshot,
  faux) and `Api::AnthropicMessages` (Anthropic). A provider's `stream` proc
  just delegates to one of them.
- `Models#stream` always calls `Transform.normalize(context, model)` before
  handing the context to the provider, so adapters can assume a normalized
  message list.
- Streaming is event-driven: every stream emits `Start`, then per-block
  `*Start`/`*Delta`/`*End` events, then exactly one terminal `Done` or `Error`
  event. `MessageStream#result` derives the final `AssistantMessage`.
- Auth resolution order is override → stored credential → environment; see
  `LLM::AI::Auth.resolve` in `src/llm-ai/auth.cr`. Credentials default to
  `~/.config/pi-ai-cr/auth.json`.
- Add new tests only where existing coverage exists; follow the `spec/*_spec.cr`
  naming and reuse the helpers in `spec/spec_helper.cr`.