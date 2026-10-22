# src/llm-ai/api/anthropic_messages.cr
require "json"

module LLM::AI::Api::AnthropicMessages
  CLAUDE_CODE_VERSION = "2.1.280"
  BETA_FINE_GRAINED   = "fine-grained-tool-streaming-2025-05-14"
  BETA_INTERLEAVED    = "interleaved-thinking-2025-05-14"
  BETA_CLAUDE_CODE    = "claude-code-20250219"
  BETA_OAUTH          = "oauth-2025-04-20"
  BETA_FALLBACK       = "server-side-fallback-2026-07-01"
  BETA_MID_CONVO      = "mid-conversation-output-config-2026-07-01"
  BETA_THINKING_BIND  = "thinking-binding-controls-2026-08-01"
  BETA_INLINE_TOOLS   = "inline-tools-2026-09-15"
  EFFORT_LEVELS       = ["low", "medium", "high", "xhigh", "max"]
  IDENTITY_PROMPT     = "You are Claude Code, Anthropic's official CLI for Claude."
  REDACTED_TEXT       = "[Reasoning redacted]"
  IMAGE_PLACEHOLDER   = "(see attached image)"
  ERROR_IMAGE_NOTE    = "[image omitted: error tool results cannot contain images]"
  KNOWN_EVENTS        = ["message_start", "message_delta", "message_stop", "content_block_start", "content_block_delta", "content_block_stop"]

  CLAUDE_CODE_TOOLS = {
    "read"            => "Read",
    "write"           => "Write",
    "edit"            => "Edit",
    "bash"            => "Bash",
    "grep"            => "Grep",
    "glob"            => "Glob",
    "askuserquestion" => "AskUserQuestion",
    "enterplanmode"   => "EnterPlanMode",
    "exitplanmode"    => "ExitPlanMode",
    "killshell"       => "KillShell",
    "notebookedit"    => "NotebookEdit",
    "skill"           => "Skill",
    "task"            => "Task",
    "taskoutput"      => "TaskOutput",
    "todowrite"       => "TodoWrite",
    "webfetch"        => "WebFetch",
    "websearch"       => "WebSearch",
  }

  class StreamState
    getter model               : Model
    getter options             : StreamOptions
    getter tools               : Array(Tool)
    getter oauth               : Bool
    getter stream              : MessageStream
    property blocks            : Array(ContentBlock)
    property block_by_index    : Hash(Int32, Int32)
    property partial_args      : Hash(Int32, String)
    property usage             : Usage?
    property stop_reason       : StopReason
    property raw_stop_reason   : String?
    property error_message     : String?
    property response_id       : String?
    property response_model    : String?
    property saw_message_start : Bool
    property saw_message_stop  : Bool
    property finished          : Bool
    property cost_model        : Model
    getter started_at          : Time::Instant

    def initialize(@model : Model, @options : StreamOptions, @tools : Array(Tool), @oauth : Bool, @stream : MessageStream)
      @blocks            = [] of ContentBlock
      @block_by_index    = {} of Int32 => Int32
      @partial_args      = {} of Int32 => String
      @usage             = nil
      @stop_reason       = StopReason::Pending
      @raw_stop_reason   = nil
      @error_message     = nil
      @response_id       = nil
      @response_model    = nil
      @saw_message_start = false
      @saw_message_stop  = false
      @finished          = false
      @cost_model        = @model
      @started_at        = Time.instant
    end
  end

  def self.stream(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?) : MessageStream
    stream = MessageStream.new(abort)
    spawn { run(model, context, options, auth, abort, stream) }
    stream
  end

  def self.build_payload(model : Model, context : Context, options : StreamOptions, oauth : Bool) : String
    resolved  = SimpleOptions.resolve(model, options)
    retention = resolve_cache_retention(options)
    payload = JSON.build do |json|
      payload(json, model, context, options, resolved, retention, oauth)
    end
    if hook = options.hooks.try(&.on_payload)
      payload = hook.call(JSON.parse(payload), model).to_json
    end
    payload
  end

  def self.handle_event(event : SSE::Event, state : StreamState) : Nil
    return if event.data.empty?
    case event.name
    when "message_start"
      handle_message_start(JSON.parse(event.data), state)
    when "message_delta"
      handle_message_delta(JSON.parse(event.data), state)
    when "message_stop"
      state.saw_message_stop = true
    when "content_block_start"
      handle_block_start(JSON.parse(event.data), state)
    when "content_block_delta"
      handle_block_delta(JSON.parse(event.data), state)
    when "content_block_stop"
      handle_block_stop(JSON.parse(event.data), state)
    end
  end

  private def self.run(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?, stream : MessageStream) : Nil
    assert_request_auth(auth)
    oauth = oauth_mode(auth)
    state = StreamState.new(model, options, context.tools, oauth, stream)
    emit(StreamEvent::Start.new(snapshot(state)), state)
    begin
      Http.request(
        "#{model.base_url}/v1/messages",
        "POST",
        request_headers(options, auth, model, context, oauth),
        build_payload(model, context, options, oauth),
        http_options(options),
        abort,
      ) do |response|
        options.hooks.try(&.on_response).try &.call(response.status_code, response.headers)
        reader = SSE::Reader.new(response.body_io)
        while event = reader.next
          break if abort.try(&.aborted?)
          if event.name == "error"
            raise ModelsError.new("stream", event.data)
          end
          next unless KNOWN_EVENTS.includes?(event.name || "")
          handle_event(event, state)
          Fiber.yield
        end
      end
      finalize(state, abort)
    rescue ex
      fail_stream(state, abort, ex)
    end
  end

  private def self.finalize(state : StreamState, abort : AbortHandle?) : Nil
    if abort.try(&.aborted?)
      state.stop_reason = StopReason::Aborted
      terminate(state, StreamEvent::Error.new(:aborted, snapshot(state, final: true)))
      return
    end
    if state.saw_message_start && !state.saw_message_stop
      state.stop_reason = StopReason::Error
      state.error_message = "Anthropic stream ended before message_stop"
      terminate(state, StreamEvent::Error.new(:error, snapshot(state, final: true)))
      return
    end
    if state.stop_reason == StopReason::Error
      state.error_message ||= "Provider returned an error stop reason"
      terminate(state, StreamEvent::Error.new(:error, snapshot(state, final: true)))
      return
    end
    if state.stop_reason == StopReason::Pending
      state.stop_reason = StopReason::Error
      state.error_message = "Anthropic stream ended without a stop reason"
      terminate(state, StreamEvent::Error.new(:error, snapshot(state, final: true)))
      return
    end
    terminate(state, StreamEvent::Done.new(state.stop_reason, snapshot(state, final: true)))
  end

  private def self.fail_stream(state : StreamState, abort : AbortHandle?, ex : Exception) : Nil
    if abort.try(&.aborted?)
      state.stop_reason = StopReason::Aborted
      terminate(state, StreamEvent::Error.new(:aborted, snapshot(state, final: true)))
    else
      state.stop_reason = StopReason::Error
      state.error_message = ex.message || ex.class.name
      terminate(state, StreamEvent::Error.new(:error, snapshot(state, final: true)))
    end
  end

  private def self.snapshot(state : StreamState, final : Bool = false) : AssistantMessage
    AssistantMessage.new(
      state.blocks.dup,
      state.model.provider,
      state.model.id,
      Time.utc,
      api: "anthropic_messages",
      response_model: state.response_model,
      response_id: state.response_id,
      provider_thinking_level: state.model.compat.supports_mid_convo_effort ? (state.options.effort || "high") : nil,
      thinking_level: state.options.thinking_level,
      usage: state.usage,
      stop_reason: state.stop_reason,
      error_message: state.error_message,
      raw_stop_reason: state.raw_stop_reason,
      duration_ms: final ? elapsed_ms(state.started_at) : nil,
    )
  end

  private def self.elapsed_ms(started_at : Time::Instant) : Int64
    (Time.instant - started_at).total_milliseconds.to_i64
  end

  private def self.emit(event : StreamEvent, state : StreamState) : Nil
    state.stream.push(event)
    state.options.hooks.try(&.on_event).try &.call(event)
  end

  private def self.terminate(state : StreamState, event : StreamEvent) : Nil
    return if state.finished
    state.finished = true
    state.stream.finish(event)
    state.options.hooks.try(&.on_event).try &.call(event)
  end

  private def self.handle_message_start(data : JSON::Any, state : StreamState) : Nil
    state.saw_message_start = true
    message = data["message"]?
    return unless message
    if id = message["id"]?.try(&.as_s?)
      state.response_id = id
    end
    if name = message["model"]?.try(&.as_s?)
      unless name.empty? || name == state.model.id
        state.response_model = name
        if fallback = state.model.compat.allowed_fallback_models.find { |entry| entry.provider == state.model.provider && entry.model == name }
          state.cost_model = priced_with(state.model, fallback)
        end
      end
    end
    if usage = message["usage"]?
      state.usage = parse_usage(usage, state)
    end
  end

  private def self.handle_message_delta(data : JSON::Any, state : StreamState) : Nil
    if delta = data["delta"]?
      if reason = delta["stop_reason"]?.try(&.as_s?)
        state.raw_stop_reason = reason
        state.stop_reason, message = map_stop_reason(reason, delta["stop_details"]?)
        state.error_message = message if message
      end
    end
    if usage = data["usage"]?
      state.usage = parse_usage(usage, state)
    end
  end

  private def self.priced_with(model : Model, fallback : FallbackModel) : Model
    Model.new(fallback.model, model.name, model.provider, model.base_url, model.api, model.input,
      model.context_window, model.max_tokens, model.reasoning, fallback.cost, model.thinking_level_map,
      model.prompt_cache, model.sampling_params, model.compat, model.sampling_params_by_thinking_level)
  end

  private def self.parse_usage(usage : JSON::Any, state : StreamState) : Usage?
    current        = state.usage
    base           = current || Usage.new(0, 0, 0, 0, 0, UsageCost.new(0.0, 0.0, 0.0, 0.0, 0.0))
    input          = usage["input_tokens"]?.try(&.as_i?) || base.input
    output         = usage["output_tokens"]?.try(&.as_i?) || base.output
    cache_read     = usage["cache_read_input_tokens"]?.try(&.as_i?) || base.cache_read
    cache_write    = usage["cache_creation_input_tokens"]?.try(&.as_i?) || base.cache_write
    cache_write_1h = usage["cache_creation"]?.try { |creation| creation["ephemeral_1h_input_tokens"]?.try(&.as_i?) } || base.cache_write_1h
    reasoning      = usage["output_tokens_details"]?.try { |details| details["thinking_tokens"]?.try(&.as_i?) } || base.reasoning
    total          = input + output + cache_read + cache_write
    seed           = Usage.new(input, output, cache_read, cache_write, total, UsageCost.new(0.0, 0.0, 0.0, 0.0, 0.0), cache_write_1h, reasoning)
    Usage.new(seed.input, seed.output, seed.cache_read, seed.cache_write, seed.total_tokens,
      Pricing.calculate(state.cost_model, seed), seed.cache_write_1h, seed.reasoning)
  end

  private def self.map_stop_reason(reason : String, details : JSON::Any?) : {StopReason, String?}
    case reason
    when "end_turn"
      {StopReason::Stop, nil}
    when "max_tokens"
      {StopReason::Length, nil}
    when "tool_use"
      {StopReason::ToolUse, nil}
    when "refusal"
      {StopReason::Error, details.try(&.["explanation"]?).try(&.as_s?) || "The model refused to complete the request"}
    when "pause_turn", "stop_sequence"
      {StopReason::Stop, nil}
    when "sensitive"
      {StopReason::Error, "Provider stopped with: sensitive"}
    else
      raise ModelsError.new("stream", "Unhandled stop reason: #{reason}")
    end
  end

  private def self.handle_block_start(data : JSON::Any, state : StreamState) : Nil
    index = data["index"]?.try(&.as_i?)
    block = data["content_block"]?
    return if index.nil? || block.nil?
    if block["type"]?.try(&.as_s?) == "fallback"
      raise ModelsError.new("stream", "Anthropic performed an unsupported mid-output model fallback") unless state.blocks.empty?
      return
    end
    idx = state.blocks.size
    state.block_by_index[index] = idx
    case block["type"]?.try(&.as_s?)
    when "text"
      state.blocks << TextContent.new(block["text"]?.try(&.as_s?) || "")
      emit(StreamEvent::TextStart.new(idx, snapshot(state)), state)
    when "thinking"
      state.blocks << ThinkingContent.new(block["thinking"]?.try(&.as_s?) || "", block["signature"]?.try(&.as_s?) || "", false)
      emit(StreamEvent::ThinkingStart.new(idx, snapshot(state)), state)
    when "redacted_thinking"
      state.blocks << ThinkingContent.new(REDACTED_TEXT, block["data"]?.try(&.as_s?), true)
      emit(StreamEvent::ThinkingStart.new(idx, snapshot(state)), state)
    when "tool_use"
      name  = block["name"]?.try(&.as_s?) || ""
      name  = from_claude_code_name(name, state.tools) if state.oauth
      input = block["input"]? || JSON::Any.new({} of String => JSON::Any)
      state.blocks << ToolCall.new(block["id"]?.try(&.as_s?) || "", name, input)
      state.partial_args[idx] = ""
      emit(StreamEvent::ToolCallStart.new(idx, snapshot(state)), state)
    end
  end

  private def self.handle_block_delta(data : JSON::Any, state : StreamState) : Nil
    index = data["index"]?.try(&.as_i?)
    delta = data["delta"]?
    return if index.nil? || delta.nil?
    idx = state.block_by_index[index]?
    return if idx.nil?
    case delta["type"]?.try(&.as_s?)
    when "text_delta"
      if block = state.blocks[idx].as?(TextContent)
        text = delta["text"]?.try(&.as_s?) || ""
        state.blocks[idx] = TextContent.new(block.text + text, block.text_signature)
        emit(StreamEvent::TextDelta.new(idx, text, snapshot(state)), state)
      end
    when "thinking_delta"
      if block = state.blocks[idx].as?(ThinkingContent)
        thinking = delta["thinking"]?.try(&.as_s?) || ""
        state.blocks[idx] = ThinkingContent.new(block.thinking + thinking, block.thinking_signature, block.redacted)
        emit(StreamEvent::ThinkingDelta.new(idx, thinking, snapshot(state)), state)
      end
    when "signature_delta"
      if block = state.blocks[idx].as?(ThinkingContent)
        signature = delta["signature"]?.try(&.as_s?) || ""
        state.blocks[idx] = ThinkingContent.new(block.thinking, (block.thinking_signature || "") + signature, block.redacted)
      end
    when "input_json_delta"
      if block = state.blocks[idx].as?(ToolCall)
        partial = (state.partial_args[idx]? || "") + (delta["partial_json"]?.try(&.as_s?) || "")
        state.partial_args[idx] = partial
        state.blocks[idx] = ToolCall.new(block.id, block.name, PartialJson.parse(partial), block.thought_signature, block.namespace)
        emit(StreamEvent::ToolCallDelta.new(idx, snapshot(state)), state)
      end
    end
  end

  private def self.handle_block_stop(data : JSON::Any, state : StreamState) : Nil
    index = data["index"]?.try(&.as_i?)
    return if index.nil?
    idx = state.block_by_index[index]?
    return if idx.nil?
    case state.blocks[idx]
    when TextContent
      emit(StreamEvent::TextEnd.new(idx, snapshot(state)), state)
    when ThinkingContent
      emit(StreamEvent::ThinkingEnd.new(idx, snapshot(state)), state)
    when ToolCall
      finalize_tool(idx, state)
    end
  end

  private def self.finalize_tool(idx : Int32, state : StreamState) : Nil
    tool      = state.blocks[idx].as(ToolCall)
    args_text = state.partial_args[idx]? || ""
    args      = JSON::Any.new({} of String => JSON::Any)
    error     = nil
    unless args_text.strip.empty?
      begin
        parsed = JSON.parse(args_text)
        if parsed.as_h?
          args = parsed
        else
          error = "Tool arguments must be a JSON object\n\nReceived arguments:\n#{args_text}"
        end
      rescue ex : JSON::Error
        error = "#{ex.message}\n\nReceived arguments:\n#{args_text}"
      end
    end
    state.blocks[idx] = ToolCall.new(tool.id, tool.name, args, tool.thought_signature, tool.namespace, error)
    emit(StreamEvent::ToolCallEnd.new(idx, snapshot(state)), state)
  end

  private def self.request_headers(options : StreamOptions, auth : Auth::AuthResult, model : Model, context : Context, oauth : Bool) : Hash(String, String)
    resolved = SimpleOptions.resolve(model, options)
    headers = {
      "Content-Type"      => "application/json",
      "Accept"            => "application/json",
      "anthropic-version" => "2023-06-01",
    } of String => String
    auth.auth.headers.try &.each { |key, value| headers[key] = value }
    if oauth
      if key = auth.auth.api_key
        headers["Authorization"] = "Bearer #{key}"
      end
      headers["user-agent"] = "claude-cli/#{CLAUDE_CODE_VERSION}"
      headers["x-app"] = "cli"
    elsif key = auth.auth.api_key
      headers["x-api-key"] = key
    end
    betas = beta_features(model, context, resolved, oauth)
    headers["anthropic-beta"] = betas.join(", ") unless betas.empty?
    options.headers.try &.each { |name, value| headers[name] = value }
    headers
  end

  private def self.beta_features(model : Model, context : Context, resolved : ResolvedOptions, oauth : Bool) : Array(String)
    features = [] of String
    features << BETA_CLAUDE_CODE << BETA_OAUTH if oauth
    unless context.tools.empty? || model.compat.supports_eager_tool_input_streaming
      features << BETA_FINE_GRAINED
    end
    if model.reasoning && resolved.thinking_enabled && !model.compat.force_adaptive_thinking
      features << BETA_INTERLEAVED
    end
    features << BETA_FALLBACK unless model.compat.allowed_fallback_models.empty?
    if model.compat.supports_mid_convo_effort
      features << BETA_MID_CONVO << BETA_THINKING_BIND
    end
    features << BETA_INLINE_TOOLS if native_tool_changes(model, context)
    features
  end

  private def self.native_tool_changes(model : Model, context : Context) : Bool
    model.compat.supports_mid_convo_system_messages && model.compat.supports_mid_convo_tool_changes && !context.tools.empty?
  end

  private def self.oauth_mode(auth : Auth::AuthResult) : Bool
    return true if auth.source == "oauth"
    key = auth.auth.api_key
    !key.nil? && key.includes?("sk-ant-oat")
  end

  private def self.assert_request_auth(auth : Auth::AuthResult) : Nil
    key = auth.auth.api_key
    return if key && !key.empty?
    if headers = auth.auth.headers
      headers.each do |name, value|
        lowered = name.downcase
        next unless lowered == "authorization" || lowered == "x-api-key"
        return unless value.strip.empty?
      end
    end
    raise ModelsError.new("auth", "No API key for provider: anthropic")
  end

  private def self.http_options(options : StreamOptions) : Http::Options
    Http::Options.new(
      read_timeout: options.timeout_ms ? options.timeout_ms.not_nil!.milliseconds : 10.minutes,
      max_retries: options.max_retries,
    )
  end

  private def self.resolve_cache_retention(options : StreamOptions) : Symbol
    if retention = options.cache_retention
      return retention
    end
    case ENV["PI_CACHE_RETENTION"]?
    when "long" then :long
    when "none" then :none
    else             :short
    end
  end

  private def self.payload(json : JSON::Builder, model : Model, context : Context, options : StreamOptions, resolved : ResolvedOptions, retention : Symbol, oauth : Bool) : Nil
    json.object do
      json.field "model", model.id
      json.field "max_tokens", resolved.max_tokens || model.max_tokens
      json.field "stream", true
      write_system(json, model, context, retention, oauth)
      json.field "messages" do
        json.array do
          build_messages(context, model, options, retention, oauth).each do |message|
            Jsonify.any(json, message)
          end
        end
      end
      write_tools(json, model, context, retention, oauth)
      write_thinking(json, model, options, resolved)
      if temperature = resolved.temperature
        if !resolved.thinking_enabled && model.compat.supports_temperature && !model.compat.supports_mid_convo_effort
          json.field "temperature", temperature
        end
      end
      if user_id = options.user_id
        json.field "metadata" do
          json.object do
            json.field "user_id", user_id
          end
        end
      end
      if tool_choice = options.tool_choice
        json.field "tool_choice" do
          json.object do
            json.field "type", tool_choice
          end
        end
      end
      unless model.compat.allowed_fallback_models.empty?
        json.field "fallbacks" do
          json.array do
            model.compat.allowed_fallback_models.each do |fallback|
              json.object do
                json.field "model", fallback.model
              end
            end
          end
        end
      end
    end
  end

  private def self.write_system(json : JSON::Builder, model : Model, context : Context, retention : Symbol, oauth : Bool) : Nil
    blocks = [] of String
    blocks << IDENTITY_PROMPT if oauth
    if prompt = context.system_prompt
      blocks << prompt unless prompt.empty?
    end
    if first = context.messages.first?
      if first.is_a?(SystemMessage)
        text = system_text(first)
        blocks << text unless text.empty?
      end
    end
    return if blocks.empty?
    json.field "system" do
      json.array do
        blocks.each do |text_block|
          json.object do
            json.field "type", "text"
            json.field "text", text_block
            write_cache_control(json, retention, model)
          end
        end
      end
    end
  end

  private def self.write_cache_control(json : JSON::Builder, retention : Symbol, model : Model) : Nil
    return if retention == :none
    json.field "cache_control" do
      json.object do
        json.field "type", "ephemeral"
        if retention == :long && model.compat.supports_long_cache_retention
          json.field "ttl", "1h"
        end
      end
    end
  end

  private def self.cache_control_value(retention : Symbol, model : Model) : JSON::Any
    fields = {"type" => JSON::Any.new("ephemeral")} of String => JSON::Any
    if retention == :long && model.compat.supports_long_cache_retention
      fields["ttl"] = JSON::Any.new("1h")
    end
    JSON::Any.new(fields)
  end

  private def self.build_messages(context : Context, model : Model, options : StreamOptions, retention : Symbol, oauth : Bool) : Array(JSON::Any)
    messages = [] of JSON::Any
    pending  = [] of JSON::Any
    native   = native_tool_changes(model, context)
    index    = 0
    while index < context.messages.size
      message = context.messages[index]
      case message
      when SystemMessage
        if index == 0
          index += 1
          next
        end
        if param = system_update_param(message, model, retention, oauth, native)
          pending << param
        end
      when UserMessage
        if param = user_param(message)
          messages << param
        end
      when AssistantMessage
        messages.concat(pending)
        pending.clear
        if param = assistant_param(message, model, oauth)
          if effort = message_effort(message, model)
            messages << effort_param(effort)
          end
          messages << param
        end
      when ToolResultMessage
        results = [] of JSON::Any
        while index < context.messages.size
          result = context.messages[index].as?(ToolResultMessage)
          break if result.nil?
          results << tool_result_param(result)
          index += 1
        end
        messages << user_param_from_blocks(results)
        next
      end
      index += 1
    end
    messages.concat(pending)
    attach_last_cache_control(messages, retention, model)
    if model.compat.supports_mid_convo_effort
      messages << effort_param(options.effort || "high")
    end
    messages
  end

  private def self.effort_param(effort : String) : JSON::Any
    object_param({
      "role"          => JSON::Any.new("system"),
      "content"       => JSON::Any.new([] of JSON::Any),
      "output_config" => object_param({"effort" => JSON::Any.new(effort)}),
    })
  end

  private def self.message_effort(message : AssistantMessage, model : Model) : String?
    return unless model.compat.supports_mid_convo_effort
    return unless message.api == "anthropic_messages" && message.provider == model.provider
    level = message.provider_thinking_level
    level if level && EFFORT_LEVELS.includes?(level)
  end

  private def self.object_param(fields : Hash(String, JSON::Any)) : JSON::Any
    JSON.parse(JSON.build do |json|
      json.object do
        fields.each do |key, value|
          json.field(key) { Jsonify.any(json, value) }
        end
      end
    end)
  end

  private def self.user_param_from_blocks(blocks : Array(JSON::Any)) : JSON::Any
    object_param({"role" => JSON::Any.new("user"), "content" => JSON::Any.new(blocks)})
  end

  private def self.user_param(message : UserMessage) : JSON::Any?
    case content = message.content
    when String
      return if content.strip.empty?
      object_param({"role" => JSON::Any.new("user"), "content" => JSON::Any.new(content)})
    else
      blocks = content.compact_map do |block|
        case block
        when TextContent
          block.text.strip.empty? ? nil : object_param({"type" => JSON::Any.new("text"), "text" => JSON::Any.new(block.text)})
        when ImageContent
          object_param({
            "type"   => JSON::Any.new("image"),
            "source" => object_param({
              "type"       => JSON::Any.new("base64"),
              "media_type" => JSON::Any.new(block.mime_type),
              "data"       => JSON::Any.new(block.data),
            }),
          })
        end
      end
      return if blocks.empty?
      user_param_from_blocks(blocks)
    end
  end

  private def self.assistant_param(message : AssistantMessage, model : Model, oauth : Bool) : JSON::Any?
    blocks = [] of JSON::Any
    message.content.each do |block|
      case block
      when TextContent
        next if block.text.strip.empty?
        blocks << object_param({"type" => JSON::Any.new("text"), "text" => JSON::Any.new(block.text)})
      when ThinkingContent
        if param = thinking_param(block, model)
          blocks << param
        end
      when ToolCall
        blocks << object_param({
          "type"  => JSON::Any.new("tool_use"),
          "id"    => JSON::Any.new(block.id),
          "name"  => JSON::Any.new(oauth ? to_claude_code_name(block.name) : block.name),
          "input" => block.arguments,
        })
      end
    end
    return if blocks.empty?
    object_param({"role" => JSON::Any.new("assistant"), "content" => JSON::Any.new(blocks)})
  end

  private def self.thinking_param(block : ThinkingContent, model : Model) : JSON::Any?
    if block.redacted
      if signature = block.thinking_signature
        return object_param({"type" => JSON::Any.new("redacted_thinking"), "data" => JSON::Any.new(signature)})
      end
      return if block.thinking.strip.empty?
      return object_param({"type" => JSON::Any.new("text"), "text" => JSON::Any.new(block.thinking)})
    end
    signature     = block.thinking_signature
    has_signature = !signature.nil? && !signature.not_nil!.strip.empty?
    return if block.thinking.strip.empty? && !has_signature
    if has_signature
      object_param({"type" => JSON::Any.new("thinking"), "thinking" => JSON::Any.new(block.thinking), "signature" => JSON::Any.new(signature.not_nil!)})
    elsif model.compat.allow_empty_signature
      object_param({"type" => JSON::Any.new("thinking"), "thinking" => JSON::Any.new(block.thinking), "signature" => JSON::Any.new("")})
    else
      object_param({"type" => JSON::Any.new("text"), "text" => JSON::Any.new(block.thinking)})
    end
  end

  private def self.tool_result_param(message : ToolResultMessage) : JSON::Any
    object_param({
      "type"        => JSON::Any.new("tool_result"),
      "tool_use_id" => JSON::Any.new(message.tool_call_id),
      "content"     => tool_result_content(message),
      "is_error"    => JSON::Any.new(message.is_error),
    })
  end

  private def self.tool_result_content(message : ToolResultMessage) : JSON::Any
    blocks = message.content.map do |block|
      case block
      when ImageContent
        message.is_error ? TextContent.new(ERROR_IMAGE_NOTE) : block
      else
        block
      end
    end
    unless blocks.any?(ImageContent)
      return JSON::Any.new(blocks.select(TextContent).map(&.text).join("\n"))
    end
    array = [] of JSON::Any
    unless blocks.any?(TextContent)
      array << object_param({"type" => JSON::Any.new("text"), "text" => JSON::Any.new(IMAGE_PLACEHOLDER)})
    end
    blocks.each do |block|
      case block
      when TextContent
        array << object_param({"type" => JSON::Any.new("text"), "text" => JSON::Any.new(block.text)})
      when ImageContent
        array << object_param({
          "type"   => JSON::Any.new("image"),
          "source" => object_param({
            "type"       => JSON::Any.new("base64"),
            "media_type" => JSON::Any.new(block.mime_type),
            "data"       => JSON::Any.new(block.data),
          }),
        })
      end
    end
    JSON::Any.new(array)
  end

  private def self.attach_last_cache_control(messages : Array(JSON::Any), retention : Symbol, model : Model) : Nil
    return if retention == :none || messages.empty?
    fields = messages.last.as_h
    role   = fields["role"]?.try(&.as_s)
    return unless role == "user" || role == "system"
    content = fields["content"]?
    return if content.nil?
    if array = content.as_a?
      return if array.empty?
      updated = array.last.as_h
      updated["cache_control"] = cache_control_value(retention, model)
      array[-1] = JSON::Any.new(updated)
      fields["content"] = JSON::Any.new(array)
      messages[-1] = JSON::Any.new(fields)
    elsif text = content.as_s?
      block = {
        "type"          => JSON::Any.new("text"),
        "text"          => JSON::Any.new(text),
        "cache_control" => cache_control_value(retention, model),
      }
      fields["content"] = JSON::Any.new([JSON::Any.new(block)])
      messages[-1] = JSON::Any.new(fields)
    end
  end

  private def self.write_tools(json : JSON::Builder, model : Model, context : Context, retention : Symbol, oauth : Bool) : Nil
    return if context.tools.empty?
    json.field "tools" do
      json.array do
        context.tools.each_with_index do |tool, index|
          write_tool(json, tool, model, retention, oauth, index == context.tools.size - 1)
        end
        if native_tool_changes(model, context)
          json.object do
            json.field "name", "__pi_deferred_placeholder__"
            json.field "description", "Reserved placeholder. Never available. Never call this."
            json.field "input_schema" do
              json.object do
                json.field "type", "object"
                json.field "properties" do
                  json.object do
                  end
                end
                json.field "required" do
                  json.array do
                  end
                end
              end
            end
            json.field "defer_loading", true
          end
        end
      end
    end
  end

  private def self.write_tool(json : JSON::Builder, tool : Tool, model : Model, retention : Symbol, oauth : Bool, cache_control : Bool) : Nil
    json.object do
      json.field "name", oauth ? to_claude_code_name(tool.name) : tool.name
      json.field "description", tool.description
      json.field "input_schema" do
        Jsonify.any(json, tool.parameters)
      end
      json.field "eager_input_streaming", true if model.compat.supports_eager_tool_input_streaming
      if model.compat.supports_cache_control_on_tools && cache_control
        write_cache_control(json, retention, model)
      end
    end
  end

  private def self.write_thinking(json : JSON::Builder, model : Model, options : StreamOptions, resolved : ResolvedOptions) : Nil
    return unless model.reasoning
    if model.compat.supports_mid_convo_effort || model.compat.force_adaptive_thinking
      if resolved.thinking_enabled
        json.field "thinking" do
          json.object do
            json.field "type", "adaptive"
            json.field "display", options.thinking_display || "summarized"
            if model.compat.supports_mid_convo_effort
              json.field "block_binding" do
                json.object do
                  json.field "prefix_mismatch_behavior", "drop_block"
                end
              end
            end
          end
        end
      end
      if model.compat.supports_mid_convo_effort
        json.field "output_config" do
          json.object do
            json.field "effort", "high"
          end
        end
      elsif resolved.thinking_enabled && (effort = resolved.effort)
        json.field "output_config" do
          json.object do
            json.field "effort", effort
          end
        end
      end
      return
    end
    if resolved.thinking_enabled
      json.field "thinking" do
        json.object do
          json.field "type", "enabled"
          budget  = resolved.thinking_budget_tokens || 1024
          ceiling = (resolved.max_tokens || model.max_tokens) - 1024
          json.field "budget_tokens", Math.max(Math.min(budget, ceiling), 0)
        end
      end
    else
      off = model.thinking_level_map["off"]?
      unless model.thinking_level_map.has_key?("off") && off.nil?
        json.field "thinking" do
          json.object do
            json.field "type", "disabled"
          end
        end
      end
    end
  end

  private def self.to_claude_code_name(name : String) : String
    CLAUDE_CODE_TOOLS[name.downcase]? || name
  end

  private def self.from_claude_code_name(name : String, tools : Array(Tool)) : String
    tools.each do |tool|
      return tool.name if tool.name.downcase == name.downcase
    end
    name
  end

  private def self.system_text(message : SystemMessage) : String
    parts = [content_text(message.content)]
    message.sections.try &.each_value do |value|
      parts << value unless value.nil?
    end
    parts.reject(&.empty?).join("\n\n")
  end

  private def self.system_update_text(message : SystemMessage) : String
    parts = [] of String
    text  = content_text(message.content)
    parts << text unless text.empty?
    message.sections.try &.each do |name, value|
      parts << (value ? "Updated system prompt section \"#{name}\":\n\n#{value}" : "Removed system prompt section \"#{name}\".")
    end
    parts.join("\n\n")
  end

  private def self.system_update_param(message : SystemMessage, model : Model, retention : Symbol, oauth : Bool, native : Bool) : JSON::Any?
    text = system_update_text(message)
    return if text.empty? && !native
    return object_param({"role" => JSON::Any.new("system"), "content" => JSON::Any.new(text)}) unless native
    blocks = [] of JSON::Any
    blocks << object_param({"type" => JSON::Any.new("text"), "text" => JSON::Any.new(text)}) unless text.empty?
    additions = message.tools_added
    redefined = additions.try(&.map(&.name)) || [] of String
    message.tools_removed.try &.each do |removed|
      next if redefined.includes?(removed.name)
      blocks << object_param({
        "type" => JSON::Any.new("tool_removal"),
        "tool" => object_param({
          "type" => JSON::Any.new("tool_reference"),
          "name" => JSON::Any.new(oauth ? to_claude_code_name(removed.name) : removed.name),
        }),
      })
    end
    additions.try &.each_with_index do |tool, index|
      blocks << tool_addition_param(tool, model, retention, oauth, index == additions.not_nil!.size - 1)
    end
    return if blocks.empty?
    object_param({"role" => JSON::Any.new("system"), "content" => JSON::Any.new(blocks)})
  end

  private def self.tool_addition_param(tool : Tool, model : Model, retention : Symbol, oauth : Bool, last : Bool) : JSON::Any
    definition = JSON.parse(JSON.build do |json|
      write_tool(json, tool, model, retention, oauth, last)
    end)
    object_param({
      "type" => JSON::Any.new("tool_addition"),
      "tool" => object_param({
        "type"       => JSON::Any.new("tool_definition"),
        "definition" => definition,
      }),
    })
  end

  private def self.content_text(content : String) : String
    content
  end

  private def self.content_text(content : Array(TextContent)) : String
    content.map(&.text).join("\n")
  end
end
