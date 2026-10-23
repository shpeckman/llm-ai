# src/llm-ai/api/moonshot_responses.cr
require "json"

module LLM::AI::Api::MoonshotResponses
  class StreamState
    getter model : Model
    getter options : StreamOptions
    getter stream : MessageStream
    property blocks : Array(ContentBlock)
    property block_by_output_index : Hash(Int64, Int32)
    property partial_args : Hash(Int32, String)
    property custom_tool : Hash(Int32, Bool)
    property usage : Usage?
    property stop_reason : StopReason
    property error_message : String?
    property response_id : String?
    property response_model : String?
    property finished : Bool
    getter started_at : Time::Instant
    property duration_ms : Int64?

    def initialize(@model : Model, @options : StreamOptions, @stream : MessageStream)
      @blocks = [] of ContentBlock
      @block_by_output_index = {} of Int64 => Int32
      @partial_args = {} of Int32 => String
      @custom_tool = {} of Int32 => Bool
      @usage = nil
      @stop_reason = StopReason::Pending
      @error_message = nil
      @response_id = nil
      @response_model = nil
      @finished = false
      @started_at = Time.instant
      @duration_ms = nil
    end
  end

  def self.build_payload(model : Model, context : Context, options : StreamOptions) : String
    resolved = SimpleOptions.resolve(model, options)
    payload = JSON.build do |json|
      payload(json, model, context, options, resolved)
    end
    if hook = options.hooks.try(&.on_payload)
      payload = hook.call(JSON.parse(payload), model).to_json
    end
    payload
  end

  def self.stream(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?) : MessageStream
    stream = MessageStream.new(abort)
    spawn { run(model, context, options, auth, abort, stream) }
    stream
  end

  def self.handle_event(event : SSE::Event, state : StreamState) : Nil
    return if event.data.empty?
    data = JSON.parse(event.data)
    state.options.hooks.try(&.on_provider_event).try &.call(data, state.model)
    case event.name
    when "response.created", "response.in_progress"
      handle_response_snapshot(data, state)
    when "response.output_item.added"
      handle_item_added(data, state)
    when "response.output_text.delta"
      handle_text_delta(data, state)
    when "response.reasoning_summary_text.delta"
      handle_thinking_delta(data, state)
    when "response.function_call_arguments.delta"
      handle_args_delta(data, state, custom: false)
    when "response.custom_tool_call_input.delta"
      handle_args_delta(data, state, custom: true)
    when "response.output_item.done"
      handle_item_done(data, state)
    when "response.completed"
      handle_completed(data, state)
    when "response.incomplete"
      handle_incomplete(data, state)
    when "response.failed"
      handle_failed(data, state)
    when "error"
      message = data["message"]?.try(&.as_s?) || data.to_json
      fail_with(state, message)
    end
  end

  private def self.run(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?, stream : MessageStream) : Nil
    state = StreamState.new(model, options, stream)
    emit(StreamEvent::Start.new(snapshot(state)), state)
    begin
      Http.request(
        "#{model.base_url}/responses",
        "POST",
        request_headers(model, options, auth),
        build_payload(model, context, options),
        Http::Options.for(options),
        abort,
      ) do |response|
        options.hooks.try(&.on_response).try &.call(response.status_code, response.headers)
        reader = SSE::Reader.new(response.body_io)
        while event = reader.next
          break if abort.try(&.aborted?)
          break if event.data == "[DONE]"
          handle_event(event, state)
          break if state.finished
          Fiber.yield
        end
      end
      finalize(state, abort)
    rescue ex
      fail_stream(state, abort, ex)
    end
  end

  private def self.finalize(state : StreamState, abort : AbortHandle?) : Nil
    return if state.finished
    state.duration_ms = elapsed_ms(state)
    if abort.try(&.aborted?)
      state.stop_reason = StopReason::Aborted
      terminate(state, StreamEvent::Error.new(:aborted, snapshot(state)))
      return
    end
    if state.stop_reason == StopReason::Pending
      state.stop_reason = state.blocks.any?(ToolCall) ? StopReason::ToolUse : StopReason::Stop
    end
    if state.stop_reason == StopReason::Error
      state.error_message ||= "Provider stream failed"
      terminate(state, StreamEvent::Error.new(:error, snapshot(state)))
      return
    end
    terminate(state, StreamEvent::Done.new(state.stop_reason, snapshot(state)))
  end

  private def self.fail_stream(state : StreamState, abort : AbortHandle?, ex : Exception) : Nil
    state.duration_ms = elapsed_ms(state)
    if abort.try(&.aborted?)
      state.stop_reason = StopReason::Aborted
      terminate(state, StreamEvent::Error.new(:aborted, snapshot(state)))
    else
      state.stop_reason = StopReason::Error
      state.error_message = ex.message || ex.class.name
      terminate(state, StreamEvent::Error.new(:error, snapshot(state)))
    end
  end

  private def self.fail_with(state : StreamState, message : String) : Nil
    state.duration_ms = elapsed_ms(state)
    state.stop_reason = StopReason::Error
    state.error_message = message
    terminate(state, StreamEvent::Error.new(:error, snapshot(state)))
  end

  private def self.handle_response_snapshot(data : JSON::Any, state : StreamState) : Nil
    response = data["response"]? || data
    if (id = response["id"]?.try(&.as_s?)) && !id.empty?
      state.response_id ||= id
    end
    if (name = response["model"]?.try(&.as_s?)) && !name.empty? && name != state.model.id
      state.response_model ||= name
    end
  end

  private def self.handle_item_added(data : JSON::Any, state : StreamState) : Nil
    item = data["item"]? || return
    output_index = data["output_index"]?.try(&.as_i64?) || return
    case item["type"]?.try(&.as_s?)
    when "message"
      idx = state.blocks.size
      state.blocks << TextContent.new("")
      state.block_by_output_index[output_index] = idx
      emit(StreamEvent::TextStart.new(idx, snapshot(state)), state)
    when "reasoning"
      idx = state.blocks.size
      state.blocks << ThinkingContent.new("")
      state.block_by_output_index[output_index] = idx
      emit(StreamEvent::ThinkingStart.new(idx, snapshot(state)), state)
    when "function_call", "custom_tool_call"
      idx = state.blocks.size
      call_id = item["call_id"]?.try(&.as_s?) || item["id"]?.try(&.as_s?) || ""
      name = item["name"]?.try(&.as_s?) || ""
      namespace = item["namespace"]?.try(&.as_s?)
      state.blocks << ToolCall.new(call_id, name, JSON::Any.new({} of String => JSON::Any), namespace: namespace)
      state.block_by_output_index[output_index] = idx
      state.custom_tool[idx] = item["type"]?.try(&.as_s?) == "custom_tool_call"
      emit(StreamEvent::ToolCallStart.new(idx, snapshot(state)), state)
    end
  end

  private def self.handle_text_delta(data : JSON::Any, state : StreamState) : Nil
    idx = block_index(data, state) || return
    delta = data["delta"]?.try(&.as_s?) || return
    return if delta.empty?
    block = state.blocks[idx].as?(TextContent) || return
    state.blocks[idx] = TextContent.new(block.text + delta, block.text_signature)
    emit(StreamEvent::TextDelta.new(idx, delta, snapshot(state)), state)
  end

  private def self.handle_thinking_delta(data : JSON::Any, state : StreamState) : Nil
    idx = block_index(data, state) || return
    delta = data["delta"]?.try(&.as_s?) || return
    return if delta.empty?
    block = state.blocks[idx].as?(ThinkingContent) || return
    state.blocks[idx] = ThinkingContent.new(block.thinking + delta, block.thinking_signature, block.redacted)
    emit(StreamEvent::ThinkingDelta.new(idx, delta, snapshot(state)), state)
  end

  private def self.handle_args_delta(data : JSON::Any, state : StreamState, custom : Bool) : Nil
    idx = block_index(data, state) || return
    delta = data["delta"]?.try(&.as_s?) || return
    tool = state.blocks[idx].as?(ToolCall) || return
    partial = (state.partial_args[idx]? || "") + delta
    state.partial_args[idx] = partial
    state.blocks[idx] = ToolCall.new(tool.id, tool.name, partial_arguments(partial, custom), tool.thought_signature, tool.namespace)
    emit(StreamEvent::ToolCallDelta.new(idx, snapshot(state)), state)
  end

  private def self.handle_item_done(data : JSON::Any, state : StreamState) : Nil
    item = data["item"]? || return
    idx = block_index(data, state) || return
    case state.blocks[idx]
    when TextContent
      emit(StreamEvent::TextEnd.new(idx, snapshot(state)), state)
    when ThinkingContent
      emit(StreamEvent::ThinkingEnd.new(idx, snapshot(state)), state)
    when ToolCall
      finalize_tool(idx, item, state)
    end
  end

  private def self.finalize_tool(idx : Int32, item : JSON::Any, state : StreamState) : Nil
    tool = state.blocks[idx].as(ToolCall)
    custom = state.custom_tool[idx]? || false
    args_text = if custom
                  item["input"]?.try(&.as_s?) || state.partial_args[idx]? || ""
                else
                  item["arguments"]?.try(&.as_s?) || state.partial_args[idx]? || ""
                end
    args = JSON::Any.new({} of String => JSON::Any)
    error = nil
    if custom
      args = JSON::Any.new({"input" => JSON::Any.new(args_text)})
    elsif !args_text.strip.empty?
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

  private def self.handle_completed(data : JSON::Any, state : StreamState) : Nil
    response = data["response"]? || data
    state.usage = parse_usage(response["usage"]?, state.model)
    handle_response_snapshot(data, state)
    state.stop_reason = state.blocks.any?(ToolCall) ? StopReason::ToolUse : StopReason::Stop
    state.duration_ms = elapsed_ms(state)
    terminate(state, StreamEvent::Done.new(state.stop_reason, snapshot(state)))
  end

  private def self.handle_incomplete(data : JSON::Any, state : StreamState) : Nil
    response = data["response"]? || data
    state.usage = parse_usage(response["usage"]?, state.model)
    handle_response_snapshot(data, state)
    reason = response["incomplete_details"]?.try { |details| details["reason"]?.try(&.as_s?) }
    if reason == "max_output_tokens"
      state.stop_reason = StopReason::Length
      state.duration_ms = elapsed_ms(state)
      terminate(state, StreamEvent::Done.new(state.stop_reason, snapshot(state)))
    else
      fail_with(state, "Response incomplete: #{reason || "unknown"}")
    end
  end

  private def self.handle_failed(data : JSON::Any, state : StreamState) : Nil
    response = data["response"]? || data
    error = response["error"]?
    message = error.try { |err| err["message"]?.try(&.as_s?) } || "Response failed"
    fail_with(state, message)
  end

  private def self.block_index(data : JSON::Any, state : StreamState) : Int32?
    output_index = data["output_index"]?.try(&.as_i64?) || return
    state.block_by_output_index[output_index]?
  end

  private def self.partial_arguments(partial : String, custom : Bool) : JSON::Any
    return JSON::Any.new({"input" => JSON::Any.new(partial)}) if custom
    PartialJson.parse(partial)
  end

  private def self.parse_usage(usage : JSON::Any?, model : Model) : Usage?
    return unless usage
    prompt = usage["input_tokens"]?.try(&.as_i?) || 0
    completion = usage["output_tokens"]?.try(&.as_i?) || 0
    details = usage["input_tokens_details"]?
    cached = details.try { |detail| detail["cached_tokens"]?.try(&.as_i?) } || 0
    cache_write = details.try { |detail| detail["cache_write_tokens"]?.try(&.as_i?) } || 0
    reasoning = usage["output_tokens_details"]?.try { |detail| detail["reasoning_tokens"]?.try(&.as_i?) } || 0
    input = Math.max(prompt - cached - cache_write, 0)
    total = input + completion + cached + cache_write
    base = Usage.new(
      input.to_i32,
      completion.to_i32,
      cached.to_i32,
      cache_write.to_i32,
      total.to_i32,
      UsageCost.new(0.0, 0.0, 0.0, 0.0, 0.0),
      reasoning: reasoning.to_i32,
    )
    Usage.new(
      base.input,
      base.output,
      base.cache_read,
      base.cache_write,
      base.total_tokens,
      Pricing.calculate(model, base),
      reasoning: base.reasoning,
    )
  end

  private def self.snapshot(state : StreamState) : AssistantMessage
    AssistantMessage.new(
      state.blocks.dup,
      state.model.provider,
      state.model.id,
      Time.utc,
      api: "moonshot_responses",
      response_model: state.response_model,
      response_id: state.response_id,
      thinking_level: state.options.thinking_level,
      usage: state.usage,
      stop_reason: state.stop_reason,
      error_message: state.error_message,
      duration_ms: state.duration_ms,
    )
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

  private def self.elapsed_ms(state : StreamState) : Int64
    (Time.instant - state.started_at).total_milliseconds.to_i64
  end

  private def self.request_headers(model : Model, options : StreamOptions, auth : Auth::AuthResult) : Hash(String, String)
    headers = Identity.headers(model, options.identity)
    headers["Content-Type"] = "application/json"
    headers["Authorization"] = "Bearer #{auth.auth.api_key}" if auth.auth.api_key
    auth.auth.headers.try &.each { |key, value| headers[key] = value }
    options.headers.try &.each { |key, value| headers[key] = value }
    headers
  end

  private def self.payload(json : JSON::Builder, model : Model, context : Context, options : StreamOptions, resolved : ResolvedOptions) : Nil
    json.object do
      json.field "model", model.id
      if prompt = context.system_prompt
        json.field "instructions", prompt unless prompt.empty?
      end
      json.field "input" do
        json.array do
          context.messages.each { |message| input_item(json, message) }
        end
      end
      json.field "stream", true
      if max_tokens = resolved.max_tokens
        json.field "max_output_tokens", max_tokens
      end
      if model.reasoning && (effort = resolved.effort)
        json.field "reasoning" do
          json.object do
            json.field "effort", effort
          end
        end
      end
      if format = options.response_format
        if format["type"]?.try(&.as_s?) == "json_schema"
          json.field "text" do
            json.object do
              json.field "format" do
                Jsonify.any(json, format)
              end
            end
          end
        end
      end
      unless context.tools.empty?
        json.field "tools" do
          json.array do
            context.tools.each { |tool| tool_definition(json, tool) }
          end
        end
        json.field "tool_choice", "auto"
      end
      json.field "prompt_cache_key", options.prompt_cache_key
      if cache_options = options.prompt_cache_options
        json.field "prompt_cache_options" do
          Jsonify.any(json, cache_options)
        end
      end
      if safety = options.safety_identifier
        json.field "safety_identifier", safety
      end
      resolved.sampling_params.each do |key, value|
        json.field key do
          Jsonify.any(json, value)
        end
      end
    end
  end

  private def self.tool_definition(json : JSON::Builder, tool : Tool) : Nil
    json.object do
      json.field "type", "function"
      json.field "name", tool.name
      json.field "description", tool.description
      json.field "parameters" do
        Jsonify.canonical(json, tool.parameters)
      end
    end
  end

  private def self.input_item(json : JSON::Builder, message : Message) : Nil
    case message
    when SystemMessage
      text = Transcript.system_update_text(message)
      unless text.empty?
        json.object do
          json.field "role", "developer"
          json.field "content", text
        end
      end
      if (added = message.tools_added) && !added.empty?
        json.object do
          json.field "type", "additional_tools"
          json.field "role", "developer"
          json.field "tools" do
            json.array do
              added.each { |tool| tool_definition(json, tool) }
            end
          end
        end
      end
    when UserMessage
      user_message(json, message)
    when AssistantMessage
      assistant_items(json, message)
    when ToolResultMessage
      json.object do
        json.field "type", "function_call_output"
        json.field "call_id", message.tool_call_id
        json.field "output", tool_result_text(message)
      end
    end
  end

  private def self.user_message(json : JSON::Builder, message : UserMessage) : Nil
    case content = message.content
    when String
      json.object do
        json.field "role", "user"
        json.field "content", content
      end
    else
      json.object do
        json.field "role", "user"
        json.field "content" do
          json.array do
            content.each do |block|
              case block
              when TextContent
                next if block.text.empty?
                json.object do
                  json.field "type", "input_text"
                  json.field "text", block.text
                end
              when ImageContent
                json.object do
                  json.field "type", "input_image"
                  json.field "image_url", "data:#{block.mime_type};base64,#{block.data}"
                end
              end
            end
          end
        end
      end
    end
  end

  private def self.assistant_items(json : JSON::Builder, message : AssistantMessage) : Nil
    thinking = message.content.select(ThinkingContent).reject(&.thinking.strip.empty?)
    thinking.each do |block|
      json.object do
        json.field "type", "reasoning"
        json.field "content" do
          json.array do
            json.object do
              json.field "type", "reasoning_text"
              json.field "text", block.thinking
            end
          end
        end
      end
    end
    text = message.content.select(TextContent).map(&.text).reject(&.strip.empty?).join("")
    unless text.empty?
      json.object do
        json.field "role", "assistant"
        json.field "content" do
          json.array do
            json.object do
              json.field "type", "output_text"
              json.field "text", text
            end
          end
        end
      end
    end
    message.content.select(ToolCall).each do |call|
      json.object do
        json.field "type", "function_call"
        json.field "call_id", call.id
        json.field "name", call.name
        json.field "namespace", call.namespace
        json.field "arguments", call.arguments.to_json
      end
    end
  end

  private def self.tool_result_text(message : ToolResultMessage) : String
    text = message.content.select(TextContent).map(&.text).join("\n")
    return text unless text.empty?
    message.content.any?(ImageContent) ? "(see attached image)" : "(no tool output)"
  end
end
