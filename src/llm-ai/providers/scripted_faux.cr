# src/llm-ai/providers/scripted_faux.cr
module LLM::AI::FauxProvider
  DEFAULT_API      = "faux"
  DEFAULT_BASE_URL = "http://localhost:0"
  DEFAULT_COST     = ModelCost.new(0.0, 0.0, 0.0, 0.0)
  DEFAULT_USAGE    = Usage.new(0, 0, 0, 0, 0, UsageCost.new(0.0, 0.0, 0.0, 0.0, 0.0))

  alias ResponseFactory = Proc(Context, StreamOptions, Scripted::State, Model, AssistantMessage)
  alias ResponseStep = AssistantMessage | ResponseFactory

  record ModelDefinition,
    id : String,
    name : String? = nil,
    reasoning : Bool = false,
    input : Array(InputKind) = [InputKind::Text, InputKind::Image],
    cost : ModelCost = DEFAULT_COST,
    context_window : Int32 = 128_000,
    max_tokens : Int32 = 16_384

  DEFAULT_MODELS = [ModelDefinition.new("faux-1", "Faux Model")]

  def self.scripted(
    provider : String = "faux",
    models : Array(ModelDefinition) = DEFAULT_MODELS,
    tokens_per_second : Float64? = nil,
    token_size : Range(Int32, Int32) = 3..5,
  ) : Scripted
    Scripted.new(provider, models, tokens_per_second, token_size)
  end

  def self.text(text : String) : TextContent
    TextContent.new(text)
  end

  def self.thinking(thinking : String) : ThinkingContent
    ThinkingContent.new(thinking)
  end

  def self.tool_call(name : String, arguments, id : String? = nil) : ToolCall
    ToolCall.new(id || random_id("tool"), name, JSON.parse(arguments.to_json))
  end

  def self.assistant_message(
    content : String | ContentBlock | Array(ContentBlock),
    stop_reason : StopReason = StopReason::Stop,
    error_message : String? = nil,
    response_id : String? = nil,
    timestamp : Time = Time.utc,
  ) : AssistantMessage
    blocks = case content
             in String              then [text(content).as(ContentBlock)]
             in ContentBlock        then [content]
             in Array(ContentBlock) then content
             end
    AssistantMessage.new(
      blocks, "faux", DEFAULT_MODELS.first.id, timestamp,
      api: DEFAULT_API, response_id: response_id, usage: DEFAULT_USAGE,
      stop_reason: stop_reason, error_message: error_message,
    )
  end

  def self.random_id(prefix : String) : String
    "#{prefix}:#{Time.utc.to_unix_ms}:#{Random::Secure.hex(6)}"
  end

  class Scripted
    class State
      property call_count : Int32 = 0
    end

    getter provider : Provider
    getter models : Array(Model)
    getter state : State = State.new
    @pending = [] of ResponseStep
    @prompt_cache = {} of String => Array(String)
    @min_token_size : Int32
    @max_token_size : Int32

    def initialize(@provider_id : String, definitions : Array(ModelDefinition), @tokens_per_second : Float64?, token_size : Range(Int32, Int32))
      @min_token_size = Math.max(1, Math.min(token_size.begin, token_size.end))
      @max_token_size = Math.max(@min_token_size, token_size.end)
      @models = definitions.map do |definition|
        Model.new(
          definition.id, definition.name || definition.id, @provider_id, DEFAULT_BASE_URL,
          ApiKind::OpenaiCompletions, definition.input, definition.context_window,
          definition.max_tokens, definition.reasoning, definition.cost,
        )
      end
      @provider = Provider.new(
        @provider_id, "Faux", DEFAULT_BASE_URL, {} of String => String,
        Auth::ProviderAuth.new, @models,
        ->(model : Model, context : Context, options : StreamOptions, _auth : Auth::AuthResult, abort : AbortHandle?) { stream(model, context, options, abort) },
      )
    end

    def model : Model
      @models.first
    end

    def model(id : String) : Model?
      @models.find { |candidate| candidate.id == id }
    end

    def responses=(responses : Array(ResponseStep)) : Nil
      @pending = responses.dup
    end

    def append_responses(responses : Array(ResponseStep)) : Nil
      @pending.concat(responses)
    end

    def append_response(&factory : Context, StreamOptions, State, Model -> AssistantMessage) : Nil
      @pending << factory
    end

    def pending_response_count : Int32
      @pending.size
    end

    def stream(model : Model, context : Context, options : StreamOptions, abort : AbortHandle?) : MessageStream
      stream = MessageStream.new(abort)
      step = @pending.shift?
      @state.call_count += 1
      spawn do
        options.hooks.try(&.on_response).try &.call(200, HTTP::Headers.new)
        if step
          stream_with_deltas(stream, resolve(step, context, options, model), abort)
        else
          message = with_usage(error_message("No more faux responses queued", model), context, options)
          stream.finish(StreamEvent::Error.new(:error, message))
        end
      rescue ex
        stream.finish(StreamEvent::Error.new(:error, error_message(ex.message || ex.class.name, model)))
      end
      stream
    end

    private def resolve(step : ResponseStep, context : Context, options : StreamOptions, model : Model) : AssistantMessage
      message = step.is_a?(AssistantMessage) ? step : step.call(context, options, @state, model)
      cloned = message.copy_with(api: DEFAULT_API, provider: @provider_id, model: model.id, usage: message.usage || DEFAULT_USAGE)
      with_usage(cloned, context, options)
    end

    private def error_message(text : String, model : Model) : AssistantMessage
      AssistantMessage.new(
        [] of ContentBlock, @provider_id, model.id, Time.utc,
        api: DEFAULT_API, usage: DEFAULT_USAGE, stop_reason: StopReason::Error, error_message: text,
      )
    end

    private def stream_with_deltas(stream : MessageStream, message : AssistantMessage, abort : AbortHandle?) : Nil
      blocks = [] of ContentBlock
      partial = -> { message.copy_with(content: blocks.dup, stop_reason: StopReason::Pending) }
      return abort_stream(stream, partial.call) if abort.try(&.aborted?)
      stream.push(StreamEvent::Start.new(partial.call))
      message.content.each_with_index do |block, index|
        return abort_stream(stream, partial.call) if abort.try(&.aborted?)
        case block
        when ThinkingContent
          blocks << ThinkingContent.new("")
          stream.push(StreamEvent::ThinkingStart.new(index, partial.call))
          chunks(block.thinking).each do |chunk|
            schedule(chunk)
            return abort_stream(stream, partial.call) if abort.try(&.aborted?)
            blocks[index] = ThinkingContent.new(blocks[index].as(ThinkingContent).thinking + chunk)
            stream.push(StreamEvent::ThinkingDelta.new(index, chunk, partial.call))
          end
          stream.push(StreamEvent::ThinkingEnd.new(index, partial.call))
        when TextContent
          blocks << TextContent.new("")
          stream.push(StreamEvent::TextStart.new(index, partial.call))
          chunks(block.text).each do |chunk|
            schedule(chunk)
            return abort_stream(stream, partial.call) if abort.try(&.aborted?)
            blocks[index] = TextContent.new(blocks[index].as(TextContent).text + chunk)
            stream.push(StreamEvent::TextDelta.new(index, chunk, partial.call))
          end
          stream.push(StreamEvent::TextEnd.new(index, partial.call))
        when ToolCall
          blocks << ToolCall.new(block.id, block.name, JSON::Any.new({} of String => JSON::Any))
          stream.push(StreamEvent::ToolCallStart.new(index, partial.call))
          chunks(block.arguments.to_json).each do |chunk|
            schedule(chunk)
            return abort_stream(stream, partial.call) if abort.try(&.aborted?)
            stream.push(StreamEvent::ToolCallDelta.new(index, partial.call))
          end
          blocks[index] = block
          stream.push(StreamEvent::ToolCallEnd.new(index, partial.call))
        end
      end
      case message.stop_reason
      when .pending?
        raise "Faux response ended without a stop reason"
      when .error?
        stream.finish(StreamEvent::Error.new(:error, message))
      when .aborted?
        stream.finish(StreamEvent::Error.new(:aborted, message))
      else
        stream.finish(StreamEvent::Done.new(message.stop_reason, message))
      end
    end

    private def abort_stream(stream : MessageStream, partial : AssistantMessage) : Nil
      aborted = partial.copy_with(stop_reason: StopReason::Aborted, error_message: "Request was aborted", timestamp: Time.utc)
      stream.finish(StreamEvent::Error.new(:aborted, aborted))
    end

    private def chunks(text : String) : Array(String)
      chars = text.chars
      pieces = [] of String
      index = 0
      while index < chars.size
        size = Math.max(1, Random.rand(@min_token_size..@max_token_size) * 4)
        pieces << chars[index, size].join
        index += size
      end
      pieces.empty? ? [""] : pieces
    end

    private def schedule(chunk : String) : Nil
      rate = @tokens_per_second
      if rate && rate > 0
        sleep (estimate_tokens(chunk) / rate).seconds
      else
        Fiber.yield
      end
    end

    private def estimate_tokens(text : String) : Int32
      (text.size / 4).ceil.to_i
    end

    private def with_usage(message : AssistantMessage, context : Context, options : StreamOptions) : AssistantMessage
      prompt = prompt_texts(context)
      prompt_length = joined_length(prompt, prompt.size)
      prompt_tokens = (prompt_length / 4).ceil.to_i
      output = estimate_tokens(assistant_text(message.content))
      input = prompt_tokens
      cache_read = 0
      cache_write = 0
      if (session = options.session_id) && options.cache_retention != :none
        if previous = @prompt_cache[session]?
          cached = common_prefix_length(previous, prompt)
          cache_read = (cached / 4).ceil.to_i
          cache_write = ((prompt_length - cached) / 4).ceil.to_i
          input = Math.max(0, prompt_tokens - cache_read)
        else
          cache_write = prompt_tokens
        end
        @prompt_cache[session] = prompt
      end
      usage = Usage.new(input, output, cache_read, cache_write, input + output + cache_read + cache_write, DEFAULT_USAGE.cost)
      message.copy_with(usage: usage)
    end

    private def prompt_texts(context : Context) : Array(String)
      messages = context.messages
      if initial = Transcript.create_initial_system_message(context.system_prompt, context.tools)
        messages = [initial.as(Message)] + messages
      end
      messages.map { |message| "#{role(message)}:#{message_text(message)}" }
    end

    private def role(message : Message) : String
      case message
      when SystemMessage     then "system"
      when UserMessage       then "user"
      when AssistantMessage  then "assistant"
      when ToolResultMessage then "toolResult"
      else                        message.class.name
      end
    end

    private def message_text(message : Message) : String
      case message
      when SystemMessage
        parts = [Transcript.system_text(message)]
        message.tools_removed.try &.each { |tool| parts << "tool-:#{tool.to_json}" }
        message.tools_added.try &.each { |tool| parts << "tool+:#{tool.to_json}" }
        parts.reject(&.empty?).join("\n")
      when UserMessage
        content = message.content
        content.is_a?(String) ? content : blocks_text(content)
      when AssistantMessage
        assistant_text(message.content)
      when ToolResultMessage
        ([message.tool_name] + message.content.map { |block| blocks_text([block]) }).join("\n")
      else
        ""
      end
    end

    private def blocks_text(content : Array(ContentBlock)) : String
      content.compact_map do |block|
        case block
        when TextContent  then block.text
        when ImageContent then "[image:#{block.mime_type}:#{block.data.size}]"
        end
      end.join("\n")
    end

    private def assistant_text(content : Array(ContentBlock)) : String
      content.compact_map do |block|
        case block
        when TextContent     then block.text
        when ThinkingContent then block.thinking
        when ToolCall        then "#{block.name}:#{block.arguments.to_json}"
        end
      end.join("\n")
    end

    private def joined_length(messages : Array(String), count : Int32) : Int32
      length = count > 0 ? (count - 1) * 2 : 0
      count.times { |index| length += messages[index].size }
      length
    end

    private def common_prefix_length(previous : Array(String), current : Array(String)) : Int32
      index = 0
      while index < previous.size && index < current.size && previous[index] == current[index]
        index += 1
      end
      rest = ->(messages : Array(String)) do
        index == messages.size ? "" : (index > 0 ? "\n\n" : "") + messages[index..].join("\n\n")
      end
      shared = rest.call(previous).each_char.zip(rest.call(current).each_char).take_while { |(left, right)| left == right }.size
      joined_length(previous, index) + shared
    end
  end
end
