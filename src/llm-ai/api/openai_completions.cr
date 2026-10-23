# src/llm-ai/api/openai_completions.cr
require "json"

module LLM::AI::Api::OpenAICompletions
  VALID_REASONING_FIELDS = ["reasoning_content", "reasoning", "reasoning_text"]

  class StreamState
    getter model : Model
    getter options : StreamOptions
    getter stream : MessageStream
    property blocks : Array(ContentBlock)
    property text_index : Int32?
    property thinking_index : Int32?
    property tool_by_index : Hash(Int64, Int32)
    property tool_by_id : Hash(String, Int32)
    property partial_args : Hash(Int32, String)
    property usage : Usage?
    property stop_reason : StopReason
    property raw_stop_reason : String?
    property error_message : String?
    property response_id : String?
    property response_model : String?
    property has_finish_reason : Bool
    property finished : Bool
    getter started_at : Time::Instant
    property streamed_details : Array(JSON::Any)
    property duration_ms : Int64?
    property reasoning_details : JSON::Any?
    property logprobs : Array(JSON::Any)

    def initialize(@model : Model, @options : StreamOptions, @stream : MessageStream)
      @blocks = [] of ContentBlock
      @text_index = nil
      @thinking_index = nil
      @tool_by_index = {} of Int64 => Int32
      @tool_by_id = {} of String => Int32
      @partial_args = {} of Int32 => String
      @usage = nil
      @stop_reason = StopReason::Pending
      @raw_stop_reason = nil
      @error_message = nil
      @response_id = nil
      @response_model = nil
      @has_finish_reason = false
      @finished = false
      @started_at = Time.instant
      @streamed_details = [] of JSON::Any
      @duration_ms = nil
      @reasoning_details = nil
      @logprobs = [] of JSON::Any
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

  def self.handle_chunk(chunk : JSON::Any, state : StreamState) : Nil
    if (id = chunk["id"]?.try(&.as_s?)) && !id.empty?
      state.response_id ||= id
    end
    if (name = chunk["model"]?.try(&.as_s?)) && !name.empty? && name != state.model.id
      state.response_model ||= name
    end
    state.usage = parse_usage(chunk["usage"], state.model) if chunk["usage"]?
    choice = chunk["choices"]?.try(&.as_a?).try(&.first?)
    return unless choice
    state.usage = parse_usage(choice["usage"], state.model) if choice["usage"]? && !chunk["usage"]?
    if finish = choice["finish_reason"]?.try(&.as_s?)
      state.raw_stop_reason = finish
      state.stop_reason, state.error_message = map_stop_reason(finish)
      state.has_finish_reason = true
    end
    if logprobs = choice["logprobs"]?
      state.logprobs << logprobs
    end
    delta = choice["delta"]?
    return unless delta
    reasoning = nil
    VALID_REASONING_FIELDS.each do |field|
      value = delta[field]?.try(&.as_s?)
      if value && !value.empty?
        reasoning = {field, value}
        break
      end
    end
    if pair = reasoning
      idx = ensure_thinking_block(pair[0], state)
      block = state.blocks[idx].as(ThinkingContent)
      state.blocks[idx] = ThinkingContent.new(block.thinking + pair[1], block.thinking_signature, block.redacted)
      emit(StreamEvent::ThinkingDelta.new(idx, pair[1], snapshot(state)), state)
    end
    if details = delta["reasoning_details"]?.try(&.as_a?)
      details.each do |detail|
        next unless entry = parse_reasoning_detail(detail)
        ensure_thinking_block("", state)
        append_reasoning_detail(entry, state.streamed_details)
      end
    end
    if (text = delta["content"]?.try(&.as_s?)) && !text.empty?
      idx = ensure_text_block(state)
      block = state.blocks[idx].as(TextContent)
      state.blocks[idx] = TextContent.new(block.text + text, block.text_signature)
      emit(StreamEvent::TextDelta.new(idx, text, snapshot(state)), state)
    end
    if tool_calls = delta["tool_calls"]?.try(&.as_a?)
      tool_calls.each { |tool_call| handle_tool_delta(tool_call, state) }
    end
  end

  private def self.run(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?, stream : MessageStream) : Nil
    state = StreamState.new(model, options, stream)
    emit(StreamEvent::Start.new(snapshot(state)), state)
    begin
      Http.request(
        "#{model.base_url}/chat/completions",
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
          chunk = JSON.parse(event.data)
          options.hooks.try(&.on_provider_event).try &.call(chunk, model)
          handle_chunk(chunk, state)
          Fiber.yield
        end
      end
      finalize(state, abort)
    rescue ex
      fail_stream(state, abort, ex)
    end
  end

  private def self.finalize(state : StreamState, abort : AbortHandle?) : Nil
    finish_blocks(state)
    state.duration_ms = elapsed_ms(state)
    state.reasoning_details = merged_details(state)
    if abort.try(&.aborted?)
      state.stop_reason = StopReason::Aborted
      terminate(state, StreamEvent::Error.new(:aborted, snapshot(state)))
      return
    end
    unless state.has_finish_reason || state.model.compat.supports_finish_reason
      state.stop_reason = state.blocks.any?(ToolCall) ? StopReason::ToolUse : StopReason::Stop
    end
    if state.stop_reason == StopReason::Error
      state.error_message ||= "Provider returned an error stop reason"
      terminate(state, StreamEvent::Error.new(:error, snapshot(state)))
      return
    end
    if (state.model.compat.supports_finish_reason && !state.has_finish_reason) || state.stop_reason == StopReason::Pending
      state.error_message = "Stream ended without finish_reason"
      terminate(state, StreamEvent::Error.new(:error, snapshot(state)))
      return
    end
    terminate(state, StreamEvent::Done.new(state.stop_reason, snapshot(state)))
  end

  private def self.fail_stream(state : StreamState, abort : AbortHandle?, ex : Exception) : Nil
    apply_streamed_signature(state)
    state.duration_ms = elapsed_ms(state)
    state.reasoning_details = merged_details(state)
    if abort.try(&.aborted?)
      state.stop_reason = StopReason::Aborted
      terminate(state, StreamEvent::Error.new(:aborted, snapshot(state)))
    else
      state.stop_reason = StopReason::Error
      state.error_message = ex.message || ex.class.name
      terminate(state, StreamEvent::Error.new(:error, snapshot(state)))
    end
  end

  private def self.finish_blocks(state : StreamState) : Nil
    apply_streamed_signature(state)
    state.blocks.each_with_index do |block, idx|
      case block
      when TextContent
        emit(StreamEvent::TextEnd.new(idx, snapshot(state)), state)
      when ThinkingContent
        emit(StreamEvent::ThinkingEnd.new(idx, snapshot(state)), state)
      when ToolCall
        finalize_tool(idx, state)
      end
    end
  end

  private def self.finalize_tool(idx : Int32, state : StreamState) : Nil
    tool = state.blocks[idx].as(ToolCall)
    args_text = state.partial_args[idx]? || ""
    args = JSON::Any.new({} of String => JSON::Any)
    error = nil
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

  private def self.handle_tool_delta(tool_call : JSON::Any, state : StreamState) : Nil
    index = tool_call["index"]?.try(&.as_i64?)
    id = tool_call["id"]?.try(&.as_s?)
    function = tool_call["function"]?
    name = function.try { |func| func["name"]?.try(&.as_s?) }
    idx = if (i = index) && (found = state.tool_by_index[i]?)
            found
          elsif (tool_id = id) && (found = state.tool_by_id[tool_id]?)
            found
          else
            new_tool_block(index, id, name, state)
          end
    tool = state.blocks[idx].as(ToolCall)
    resolved_id = tool.id.empty? ? (id || "") : tool.id
    resolved_name = tool.name.empty? ? (name || "") : tool.name
    if args_delta = function.try { |func| func["arguments"]?.try(&.as_s?) }
      partial = state.partial_args[idx]? || ""
      partial += args_delta
      state.partial_args[idx] = partial
    end
    partial = state.partial_args[idx]? || ""
    state.blocks[idx] = ToolCall.new(resolved_id, resolved_name, PartialJson.parse(partial), tool.thought_signature, tool.namespace)
    emit(StreamEvent::ToolCallDelta.new(idx, snapshot(state)), state)
  end

  private def self.new_tool_block(index : Int64?, id : String?, name : String?, state : StreamState) : Int32
    idx = state.blocks.size
    state.blocks << ToolCall.new(id || "", name || "", JSON::Any.new({} of String => JSON::Any))
    state.tool_by_index[index] = idx if index
    state.tool_by_id[id] = idx if id && !id.empty?
    emit(StreamEvent::ToolCallStart.new(idx, snapshot(state)), state)
    idx
  end

  private def self.ensure_text_block(state : StreamState) : Int32
    if idx = state.text_index
      idx
    else
      idx = state.blocks.size
      state.text_index = idx
      state.blocks << TextContent.new("")
      emit(StreamEvent::TextStart.new(idx, snapshot(state)), state)
      idx
    end
  end

  private def self.ensure_thinking_block(signature : String, state : StreamState) : Int32
    if idx = state.thinking_index
      idx
    else
      idx = state.blocks.size
      state.thinking_index = idx
      state.blocks << ThinkingContent.new("", signature)
      emit(StreamEvent::ThinkingStart.new(idx, snapshot(state)), state)
      idx
    end
  end

  private def self.snapshot(state : StreamState) : AssistantMessage
    AssistantMessage.new(
      state.blocks.dup,
      state.model.provider,
      state.model.id,
      Time.utc,
      api: "openai_completions",
      response_model: state.response_model,
      response_id: state.response_id,
      thinking_level: state.options.thinking_level,
      usage: state.usage,
      stop_reason: state.stop_reason,
      error_message: state.error_message,
      raw_stop_reason: state.raw_stop_reason,
      duration_ms: state.duration_ms,
      reasoning_details: state.reasoning_details,
      logprobs: merged_logprobs(state),
    )
  end

  private def self.merged_logprobs(state : StreamState) : JSON::Any?
    return if state.logprobs.empty?
    JSON::Any.new(state.logprobs)
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

  private def self.merged_details(state : StreamState) : JSON::Any?
    return if state.streamed_details.empty?
    JSON::Any.new(state.streamed_details)
  end

  private def self.apply_streamed_signature(state : StreamState) : Nil
    return if state.streamed_details.empty?
    signature = state.streamed_details.to_json
    state.blocks.each_with_index do |block, idx|
      if thinking = block.as?(ThinkingContent)
        state.blocks[idx] = ThinkingContent.new(thinking.thinking, signature, thinking.redacted)
      end
    end
  end

  private def self.parse_reasoning_detail(detail : JSON::Any) : JSON::Any?
    hash = detail.as_h? || return
    if (id = hash["id"]?) && !id.raw.nil? && !id.as_s?
      return
    end
    if (format = hash["format"]?) && !format.as_s?
      return
    end
    if (index = hash["index"]?) && !index.as_i64? && !index.as_f?
      return
    end
    case hash["type"]?.try(&.as_s?)
    when "reasoning.summary"
      return unless hash["summary"]?.try(&.as_s?)
    when "reasoning.encrypted"
      return unless hash["data"]?.try(&.as_s?)
    when "reasoning.text"
      return unless hash["text"]?.try(&.as_s?)
      if (signature = hash["signature"]?) && !signature.raw.nil? && !signature.as_s?
        return
      end
    else
      return
    end
    detail
  end

  private def self.append_reasoning_detail(detail : JSON::Any, details : Array(JSON::Any)) : Nil
    if last = details.last?
      last_type = last["type"].as_s
      type = detail["type"].as_s
      if type == last_type
        case type
        when "reasoning.text"
          details[-1] = merge_reasoning_detail(last, detail, "text", signature: true)
          return
        when "reasoning.summary"
          details[-1] = merge_reasoning_detail(last, detail, "summary")
          return
        end
      end
    end
    details << detail
  end

  private def self.merge_reasoning_detail(last : JSON::Any, detail : JSON::Any, field : String, signature : Bool = false) : JSON::Any
    merged = last.as_h.dup
    merged[field] = JSON::Any.new(last[field].as_s + detail[field].as_s)
    if signature
      existing = merged["signature"]?.try(&.as_s?)
      if (incoming = detail["signature"]?.try(&.as_s?)) && (existing.nil? || existing.empty?)
        merged["signature"] = JSON::Any.new(incoming)
      end
    end
    if (incoming = detail["id"]?) && !incoming.raw.nil?
      merged["id"] = incoming unless merged["id"]?.try(&.as_s?)
    end
    if incoming = detail["format"]?.try(&.as_s?)
      existing = merged["format"]?.try(&.as_s?)
      merged["format"] = JSON::Any.new(incoming) if existing.nil? || existing.empty?
    end
    if incoming = detail["index"]?.try(&.as_i64?)
      merged["index"] = JSON::Any.new(incoming) unless merged["index"]?.try(&.as_i64?)
    end
    JSON::Any.new(merged)
  end

  private def self.parse_reasoning_details(signature : String?) : JSON::Any?
    return unless signature
    parsed = JSON.parse(signature) rescue nil
    return unless parsed
    array = parsed.as_a? || return
    return if array.empty?
    return unless array.all? { |detail| parse_reasoning_detail(detail) }
    parsed
  end

  private def self.parse_usage(usage : JSON::Any?, model : Model) : Usage?
    return unless usage
    prompt = usage["prompt_tokens"]?.try(&.as_i?) || 0
    completion = usage["completion_tokens"]?.try(&.as_i?) || 0
    details = usage["prompt_tokens_details"]?
    cached = details.try { |detail| detail["cached_tokens"]?.try(&.as_i?) } ||
             usage["prompt_cache_hit_tokens"]?.try(&.as_i?) ||
             usage["cached_tokens"]?.try(&.as_i?) || 0
    cache_write = details.try { |detail| detail["cache_write_tokens"]?.try(&.as_i?) } || 0
    reasoning = usage["completion_tokens_details"]?.try { |detail| detail["reasoning_tokens"]?.try(&.as_i?) } || 0
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

  private def self.map_stop_reason(reason : String) : {StopReason, String?}
    case reason
    when "stop", "end"
      {StopReason::Stop, nil}
    when "length"
      {StopReason::Length, nil}
    when "function_call", "tool_calls"
      {StopReason::ToolUse, nil}
    else
      {StopReason::Error, "Provider finish_reason: #{reason}"}
    end
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
      json.field "messages" do
        json.array do
          if prompt = context.system_prompt
            unless prompt.empty?
              json.object do
                json.field "role", "system"
                json.field "content", prompt
              end
            end
          end
          index = 0
          while index < context.messages.size
            message = context.messages[index]
            case message
            when SystemMessage
              system_message(json, message, index, model)
              index += 1
            when UserMessage
              user_message(json, message)
              index += 1
            when AssistantMessage
              assistant_message(json, model, message)
              index += 1
            when ToolResultMessage
              images = [] of ImageContent
              while index < context.messages.size && (tool = context.messages[index].as?(ToolResultMessage))
                tool_message(json, model, tool, images)
                index += 1
              end
              if images.present?
                tool_results_ack(json) if model.compat.requires_assistant_after_tool_result
                attached_images_message(json, images)
              end
            end
          end
        end
      end
      json.field "stream", true
      unless model.compat.supports_usage_in_streaming == false
        json.field "stream_options" do
          json.object do
            json.field "include_usage", true
          end
        end
      end
      json.field "store", false if model.compat.supports_store
      if max_tokens = resolved.max_tokens || (resolved.thinking_enabled ? model.max_tokens : nil)
        json.field model.compat.max_tokens_field.to_s, max_tokens
      end
      json.field "temperature", resolved.temperature if resolved.temperature
      if model.compat.supports_response_format && (format = options.response_format)
        json.field "response_format" do
          Jsonify.any(json, format)
        end
      end
      if model.compat.supports_stop && (stop = options.stop) && !stop.empty?
        json.field "stop", stop
      end
      if model.compat.supports_prediction && (prediction = options.prediction)
        json.field "prediction" do
          Jsonify.any(json, prediction)
        end
      end
      if model.compat.supports_logprobs
        json.field "logprobs", true if options.logprobs
        if top = options.top_logprobs
          json.field "top_logprobs", top
        end
      end
      if model.compat.supports_prompt_cache_key
        json.field "prompt_cache_key", options.prompt_cache_key
        if cache_options = options.prompt_cache_options
          json.field "prompt_cache_options" do
            Jsonify.any(json, cache_options)
          end
        end
      end
      if model.compat.supports_safety_identifier && (safety = options.safety_identifier)
        json.field "safety_identifier", safety
      end
      if context.tools.empty?
        if has_tool_history(context)
          json.field "tools" do
            json.array do
            end
          end
        end
      else
        json.field "tools" do
          json.array do
            context.tools.each { |tool| tool_definition(json, tool) }
          end
        end
      end
      if tool_choice = options.tool_choice
        json.field "tool_choice", tool_choice
      end
      if model.reasoning
        case model.compat.thinking_format
        when :deepseek
          if resolved.thinking_enabled
            json.field "thinking" do
              json.object do
                json.field "type", "enabled"
              end
            end
            json.field "reasoning_effort", resolved.effort || "high"
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
        else
          if effort = resolved.effort
            json.field "reasoning_effort", effort
          end
        end
      end
      resolved.sampling_params.each do |key, value|
        json.field key do
          Jsonify.any(json, value)
        end
      end
    end
  end

  private def self.system_message(json : JSON::Builder, message : SystemMessage, index : Int32, model : Model) : Nil
    if (added = message.tools_added) && !added.empty? &&
       index > 0 &&
       model.compat.supports_mid_convo_system_messages &&
       model.compat.supports_mid_convo_tool_additions
      json.object do
        json.field "role", "system"
        json.field "tools" do
          json.array do
            added.each { |tool| kimi_tool_definition(json, tool) }
          end
        end
      end
    end
    text = index == 0 ? Transcript.system_text(message) : Transcript.system_update_text(message)
    return if text.empty?
    json.object do
      json.field "role", "system"
      json.field "content", text
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
                  json.field "type", "text"
                  json.field "text", block.text
                end
              when ImageContent
                json.object do
                  json.field "type", "image_url"
                  json.field "image_url" do
                    json.object do
                      json.field "url", "data:#{block.mime_type};base64,#{block.data}"
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  private def self.assistant_message(json : JSON::Builder, model : Model, message : AssistantMessage) : Nil
    text = message.content.select(TextContent).map(&.text).reject(&.strip.empty?).join("")
    tool_calls = message.content.select(ToolCall)
    thinking = message.content.select(ThinkingContent).reject(&.thinking.strip.empty?)
    thinking_text = thinking.map(&.thinking).join("\n\n")
    return if text.empty? && tool_calls.empty? && thinking.empty?
    preserved_details = nil
    message.content.select(ThinkingContent).each do |block|
      if details = parse_reasoning_details(block.thinking_signature)
        preserved_details = details
        break
      end
    end
    reasoning_content = ""
    unless preserved_details
      if (first = thinking.first?) && (signature = first.thinking_signature) && VALID_REASONING_FIELDS.includes?(signature)
        reasoning_content = thinking.map(&.thinking).join("\n")
      end
    end
    json.object do
      json.field "role", "assistant"
      json.field "content" do
        if !text.empty?
          json.string(text)
        elsif tool_calls.empty?
          json.array do
            json.object do
              json.field "type", "text"
              json.field "text", thinking_text
            end
          end
        else
          json.null
        end
      end
      if preserved = preserved_details
        json.field "reasoning_details" do
          Jsonify.any(json, preserved)
        end
      end
      if model.compat.requires_reasoning_content_on_assistant_messages && model.reasoning
        json.field "reasoning_content", reasoning_content
      end
      unless tool_calls.empty?
        json.field "tool_calls" do
          json.array do
            tool_calls.each do |call|
              json.object do
                json.field "id", call.id
                json.field "type", "function"
                json.field "function" do
                  json.object do
                    json.field "name", call.name
                    json.field "arguments" do
                      Jsonify.any(json, call.arguments)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  private def self.tool_definition(json : JSON::Builder, tool : Tool) : Nil
    json.object do
      json.field "type", "function"
      json.field "function" do
        json.object do
          json.field "name", tool.name
          json.field "description", tool.description
          json.field "parameters" do
            Jsonify.canonical(json, tool.parameters)
          end
        end
      end
    end
  end

  private def self.kimi_tool_definition(json : JSON::Builder, tool : Tool) : Nil
    json.object do
      json.field "name", tool.name
      json.field "description", tool.description
      json.field "parameters" do
        Jsonify.canonical(json, tool.parameters)
      end
    end
  end

  private def self.tool_result_text(message : ToolResultMessage) : String
    text = message.content.select(TextContent).map(&.text).join("\n")
    return text unless text.empty?
    message.content.any?(ImageContent) ? "(see attached image)" : "(no tool output)"
  end

  private def self.tool_message(json : JSON::Builder, model : Model, message : ToolResultMessage, images : Array(ImageContent)) : Nil
    json.object do
      json.field "role", "tool"
      json.field "content", tool_result_text(message)
      json.field "tool_call_id", message.tool_call_id
      if model.compat.requires_tool_result_name && !message.tool_name.empty?
        json.field "name", message.tool_name
      end
    end
    if model.input.includes?(InputKind::Image)
      message.content.select(ImageContent).each { |block| images << block }
    end
  end

  private def self.tool_results_ack(json : JSON::Builder) : Nil
    json.object do
      json.field "role", "assistant"
      json.field "content", "I have processed the tool results."
    end
  end

  private def self.attached_images_message(json : JSON::Builder, images : Array(ImageContent)) : Nil
    json.object do
      json.field "role", "user"
      json.field "content" do
        json.array do
          json.object do
            json.field "type", "text"
            json.field "text", "Attached image(s) from tool result:"
          end
          images.each do |block|
            json.object do
              json.field "type", "image_url"
              json.field "image_url" do
                json.object do
                  json.field "url", "data:#{block.mime_type};base64,#{block.data}"
                end
              end
            end
          end
        end
      end
    end
  end

  private def self.has_tool_history(context : Context) : Bool
    context.messages.any? do |message|
      case message
      when AssistantMessage  then message.content.any?(ToolCall)
      when ToolResultMessage then true
      else                        false
      end
    end
  end
end
