# src/llm-ai/types.cr
require "http"
require "json"

module LLM::AI
  module EpochMillis
    def self.from_json(pull : JSON::PullParser) : Time
      Time.unix_ms(pull.read_int)
    end

    def self.to_json(value : Time, json : JSON::Builder)
      json.number(value.to_unix_ms)
    end
  end

  module SymbolName
    def self.from_json(pull : JSON::PullParser) : Symbol
      case pull.read_string
      when "error"                 then :error
      when "aborted"               then :aborted
      when "max_tokens"            then :max_tokens
      when "max_completion_tokens" then :max_completion_tokens
      when "deepseek"              then :deepseek
      when "openai"                then :openai
      when "none"                  then :none
      when "short"                 then :short
      when "long"                  then :long
      else
        pull.raise "Unknown symbol name"
      end
    end

    def self.to_json(value : Symbol, json : JSON::Builder)
      json.string(value.to_s)
    end
  end

  enum StopReason
    Pending
    Stop
    Length
    ToolUse
    Error
    Aborted
    Deferred
  end

  enum ApiKind
    OpenaiCompletions
    AnthropicMessages
  end

  enum InputKind
    Text
    Image
  end

  abstract class ContentBlock
    include JSON::Serializable
  end

  class TextContent < ContentBlock
    include JSON::Serializable

    getter text           : String
    getter text_signature : String?

    def initialize(@text : String, @text_signature : String? = nil)
    end

    def ==(other : TextContent) : Bool
      text == other.text && text_signature == other.text_signature
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "text"
    end
  end

  class ThinkingContent < ContentBlock
    include JSON::Serializable

    getter thinking           : String
    getter thinking_signature : String?
    getter redacted           : Bool

    def initialize(@thinking : String, @thinking_signature : String? = nil, @redacted : Bool = false)
    end

    def ==(other : ThinkingContent) : Bool
      thinking == other.thinking && thinking_signature == other.thinking_signature && redacted == other.redacted
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "thinking"
    end
  end

  class ImageContent < ContentBlock
    include JSON::Serializable

    getter data      : String
    getter mime_type : String

    def initialize(@data : String, @mime_type : String)
    end

    def ==(other : ImageContent) : Bool
      data == other.data && mime_type == other.mime_type
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "image"
    end
  end

  class ToolCall < ContentBlock
    include JSON::Serializable

    getter id                : String
    getter name              : String
    getter arguments         : JSON::Any
    getter thought_signature : String?
    getter namespace         : String?
    getter arguments_error   : String?

    def initialize(
      @id : String,
      @name : String,
      @arguments : JSON::Any,
      @thought_signature : String? = nil,
      @namespace : String? = nil,
      @arguments_error : String? = nil,
    )
    end

    def ==(other : ToolCall) : Bool
      id == other.id && name == other.name && arguments == other.arguments &&
        thought_signature == other.thought_signature && namespace == other.namespace &&
        arguments_error == other.arguments_error
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "toolCall"
    end
  end

  abstract class ContentBlock
    use_json_discriminator "type", {
      text:     TextContent,
      thinking: ThinkingContent,
      image:    ImageContent,
      toolCall: ToolCall,
    }
  end

  struct UsageCost
    include JSON::Serializable

    getter input       : Float64
    getter output      : Float64
    getter cache_read  : Float64
    getter cache_write : Float64
    getter total       : Float64

    def initialize(@input : Float64, @output : Float64, @cache_read : Float64, @cache_write : Float64, @total : Float64)
    end
  end

  struct Usage
    include JSON::Serializable

    getter input          : Int32
    getter output         : Int32
    getter cache_read     : Int32
    getter cache_write    : Int32
    getter cache_write_1h : Int32?
    getter reasoning      : Int32?
    getter total_tokens   : Int32
    getter cost           : UsageCost

    def initialize(
      @input : Int32,
      @output : Int32,
      @cache_read : Int32,
      @cache_write : Int32,
      @total_tokens : Int32,
      @cost : UsageCost,
      @cache_write_1h : Int32? = nil,
      @reasoning : Int32? = nil,
    )
    end
  end

  struct ToolReference
    include JSON::Serializable

    getter name : String

    def initialize(@name : String)
    end
  end

  struct Tool
    include JSON::Serializable

    getter name        : String
    getter description : String
    getter parameters  : JSON::Any

    def initialize(@name : String, @description : String, @parameters : JSON::Any)
    end
  end

  abstract class Message
    include JSON::Serializable
  end

  class SystemMessage < Message
    include JSON::Serializable

    getter content       : String | Array(TextContent)
    getter sections      : Hash(String, String?)?
    getter tools_added   : Array(Tool)?
    getter tools_removed : Array(ToolReference)?
    @[JSON::Field(converter: LLM::AI::EpochMillis)]
    getter timestamp : Time

    def initialize(
      @content : String | Array(TextContent),
      @timestamp : Time,
      @sections : Hash(String, String?)? = nil,
      @tools_added : Array(Tool)? = nil,
      @tools_removed : Array(ToolReference)? = nil,
    )
    end

    def ==(other : SystemMessage) : Bool
      content == other.content && sections == other.sections &&
        tools_added == other.tools_added && tools_removed == other.tools_removed &&
        timestamp == other.timestamp
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "role", "system"
    end
  end

  class UserMessage < Message
    include JSON::Serializable

    getter content : String | Array(ContentBlock)
    @[JSON::Field(converter: LLM::AI::EpochMillis)]
    getter timestamp : Time

    def initialize(@content : String | Array(ContentBlock), @timestamp : Time)
    end

    def ==(other : UserMessage) : Bool
      content == other.content && timestamp == other.timestamp
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "role", "user"
    end
  end

  class AssistantMessage < Message
    include JSON::Serializable

    getter content                 : Array(ContentBlock)
    getter provider                : String
    getter model                   : String
    getter api                     : String?
    getter response_model          : String?
    getter response_id             : String?
    getter provider_thinking_level : String?
    getter thinking_level          : String?
    getter usage                   : Usage?
    getter stop_reason             : StopReason
    getter deferred                : Bool
    getter error_message           : String?
    getter raw_stop_reason         : String?
    getter end_turn                : Bool
    @[JSON::Field(converter: LLM::AI::EpochMillis)]
    getter timestamp         : Time
    getter duration_ms       : Int64?
    getter reasoning_details : JSON::Any?

    def initialize(
      @content : Array(ContentBlock),
      @provider : String,
      @model : String,
      @timestamp : Time,
      @api : String? = nil,
      @response_model : String? = nil,
      @response_id : String? = nil,
      @provider_thinking_level : String? = nil,
      @thinking_level : String? = nil,
      @usage : Usage? = nil,
      @stop_reason : StopReason = StopReason::Pending,
      @deferred : Bool = false,
      @error_message : String? = nil,
      @raw_stop_reason : String? = nil,
      @end_turn : Bool = false,
      @duration_ms : Int64? = nil,
      @reasoning_details : JSON::Any? = nil,
    )
    end

    def ==(other : AssistantMessage) : Bool
      content == other.content && provider == other.provider && model == other.model &&
        api == other.api && response_model == other.response_model &&
        response_id == other.response_id && provider_thinking_level == other.provider_thinking_level &&
        thinking_level == other.thinking_level && usage == other.usage &&
        stop_reason == other.stop_reason && deferred == other.deferred &&
        error_message == other.error_message && raw_stop_reason == other.raw_stop_reason &&
        end_turn == other.end_turn && timestamp == other.timestamp &&
        duration_ms == other.duration_ms && reasoning_details == other.reasoning_details
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "role", "assistant"
    end
  end

  class ToolResultMessage < Message
    include JSON::Serializable

    getter tool_call_id : String
    getter tool_name    : String
    getter content      : Array(ContentBlock)
    getter is_error     : Bool
    @[JSON::Field(converter: LLM::AI::EpochMillis)]
    getter timestamp   : Time
    getter duration_ms : Int64?

    def initialize(
      @tool_call_id : String,
      @tool_name : String,
      @content : Array(ContentBlock),
      @timestamp : Time,
      @is_error : Bool = false,
      @duration_ms : Int64? = nil,
    )
    end

    def ==(other : ToolResultMessage) : Bool
      tool_call_id == other.tool_call_id && tool_name == other.tool_name &&
        content == other.content && is_error == other.is_error &&
        timestamp == other.timestamp && duration_ms == other.duration_ms
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "role", "toolResult"
    end
  end

  abstract class Message
    use_json_discriminator "role", {
      system:     SystemMessage,
      user:       UserMessage,
      assistant:  AssistantMessage,
      toolResult: ToolResultMessage,
    }
  end

  abstract class StreamEvent
    include JSON::Serializable
  end

  class StreamEvent::Start < StreamEvent
    include JSON::Serializable

    getter partial : AssistantMessage

    def initialize(@partial : AssistantMessage)
    end

    def ==(other : Start) : Bool
      partial == other.partial
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "start"
    end
  end

  class StreamEvent::TextStart < StreamEvent
    include JSON::Serializable

    getter content_index : Int32
    getter partial       : AssistantMessage

    def initialize(@content_index : Int32, @partial : AssistantMessage)
    end

    def ==(other : TextStart) : Bool
      content_index == other.content_index && partial == other.partial
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "text_start"
    end
  end

  class StreamEvent::TextDelta < StreamEvent
    include JSON::Serializable

    getter content_index : Int32
    getter text          : String
    getter partial       : AssistantMessage

    def initialize(@content_index : Int32, @text : String, @partial : AssistantMessage)
    end

    def ==(other : TextDelta) : Bool
      content_index == other.content_index && text == other.text && partial == other.partial
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "text_delta"
    end
  end

  class StreamEvent::TextEnd < StreamEvent
    include JSON::Serializable

    getter content_index : Int32
    getter partial       : AssistantMessage

    def initialize(@content_index : Int32, @partial : AssistantMessage)
    end

    def ==(other : TextEnd) : Bool
      content_index == other.content_index && partial == other.partial
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "text_end"
    end
  end

  class StreamEvent::ThinkingStart < StreamEvent
    include JSON::Serializable

    getter content_index : Int32
    getter partial       : AssistantMessage

    def initialize(@content_index : Int32, @partial : AssistantMessage)
    end

    def ==(other : ThinkingStart) : Bool
      content_index == other.content_index && partial == other.partial
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "thinking_start"
    end
  end

  class StreamEvent::ThinkingDelta < StreamEvent
    include JSON::Serializable

    getter content_index : Int32
    getter thinking      : String
    getter partial       : AssistantMessage

    def initialize(@content_index : Int32, @thinking : String, @partial : AssistantMessage)
    end

    def ==(other : ThinkingDelta) : Bool
      content_index == other.content_index && thinking == other.thinking && partial == other.partial
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "thinking_delta"
    end
  end

  class StreamEvent::ThinkingEnd < StreamEvent
    include JSON::Serializable

    getter content_index : Int32
    getter partial       : AssistantMessage

    def initialize(@content_index : Int32, @partial : AssistantMessage)
    end

    def ==(other : ThinkingEnd) : Bool
      content_index == other.content_index && partial == other.partial
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "thinking_end"
    end
  end

  class StreamEvent::ToolCallStart < StreamEvent
    include JSON::Serializable

    getter content_index : Int32
    getter partial       : AssistantMessage

    def initialize(@content_index : Int32, @partial : AssistantMessage)
    end

    def ==(other : ToolCallStart) : Bool
      content_index == other.content_index && partial == other.partial
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "toolcall_start"
    end
  end

  class StreamEvent::ToolCallDelta < StreamEvent
    include JSON::Serializable

    getter content_index : Int32
    getter partial       : AssistantMessage

    def initialize(@content_index : Int32, @partial : AssistantMessage)
    end

    def ==(other : ToolCallDelta) : Bool
      content_index == other.content_index && partial == other.partial
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "toolcall_delta"
    end
  end

  class StreamEvent::ToolCallEnd < StreamEvent
    include JSON::Serializable

    getter content_index : Int32
    getter partial       : AssistantMessage

    def initialize(@content_index : Int32, @partial : AssistantMessage)
    end

    def ==(other : ToolCallEnd) : Bool
      content_index == other.content_index && partial == other.partial
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "toolcall_end"
    end
  end

  class StreamEvent::Done < StreamEvent
    include JSON::Serializable

    getter reason  : StopReason
    getter message : AssistantMessage

    def initialize(@reason : StopReason, @message : AssistantMessage)
    end

    def ==(other : Done) : Bool
      reason == other.reason && message == other.message
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "done"
    end
  end

  class StreamEvent::Error < StreamEvent
    include JSON::Serializable

    @[JSON::Field(converter: LLM::AI::SymbolName)]
    getter reason  : Symbol
    getter message : AssistantMessage

    def initialize(@reason : Symbol, @message : AssistantMessage)
    end

    def ==(other : Error) : Bool
      reason == other.reason && message == other.message
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "error"
    end
  end

  abstract class StreamEvent
    use_json_discriminator "type", {
      start:          Start,
      text_start:     TextStart,
      text_delta:     TextDelta,
      text_end:       TextEnd,
      thinking_start: ThinkingStart,
      thinking_delta: ThinkingDelta,
      thinking_end:   ThinkingEnd,
      toolcall_start: ToolCallStart,
      toolcall_delta: ToolCallDelta,
      toolcall_end:   ToolCallEnd,
      done:           Done,
      error:          Error,
    }
  end

  struct CostTier
    include JSON::Serializable

    getter above : Int32
    getter cost  : ModelCost

    def initialize(@above : Int32, @cost : ModelCost)
    end
  end

  struct ModelCost
    include JSON::Serializable

    getter input          : Float64
    getter output         : Float64
    getter cache_read     : Float64
    getter cache_write    : Float64
    getter cache_write_1h : Float64?
    getter tiers          : Array(CostTier)

    def initialize(
      @input : Float64,
      @output : Float64,
      @cache_read : Float64,
      @cache_write : Float64,
      @cache_write_1h : Float64? = nil,
      @tiers : Array(CostTier) = [] of CostTier,
    )
    end
  end

  struct FallbackModel
    include JSON::Serializable

    getter provider : String
    getter model    : String
    getter cost     : ModelCost

    def initialize(@provider : String, @model : String, @cost : ModelCost)
    end
  end

  struct Compat
    include JSON::Serializable

    @[JSON::Field(converter: LLM::AI::SymbolName)]
    getter max_tokens_field : Symbol
    @[JSON::Field(converter: LLM::AI::SymbolName)]
    getter thinking_format                                  : Symbol?
    getter requires_reasoning_content_on_assistant_messages : Bool
    getter supports_finish_reason                           : Bool
    getter supports_usage_in_streaming                      : Bool
    getter supports_store                                   : Bool
    getter supports_developer_role                          : Bool
    getter supports_mid_convo_tool_additions                : Bool
    getter supports_temperature                             : Bool
    getter supports_eager_tool_input_streaming              : Bool
    getter supports_long_cache_retention                    : Bool
    getter supports_cache_control_on_tools                  : Bool
    getter supports_strict_tools                            : Bool
    getter allow_empty_signature                            : Bool
    getter force_adaptive_thinking                          : Bool
    getter supports_mid_convo_system_messages               : Bool
    getter supports_mid_convo_tool_changes                  : Bool
    getter supports_mid_convo_effort                        : Bool
    getter allowed_fallback_models                          : Array(FallbackModel)
    getter requires_tool_result_name                        : Bool
    getter requires_assistant_after_tool_result             : Bool

    def initialize(
      @max_tokens_field : Symbol = :max_completion_tokens,
      @thinking_format : Symbol? = nil,
      @requires_reasoning_content_on_assistant_messages : Bool = false,
      @supports_finish_reason : Bool = true,
      @supports_usage_in_streaming : Bool = true,
      @supports_store : Bool = true,
      @supports_developer_role : Bool = false,
      @supports_mid_convo_tool_additions : Bool = false,
      @supports_temperature : Bool = true,
      @supports_eager_tool_input_streaming : Bool = true,
      @supports_long_cache_retention : Bool = true,
      @supports_cache_control_on_tools : Bool = true,
      @supports_strict_tools : Bool = false,
      @allow_empty_signature : Bool = false,
      @force_adaptive_thinking : Bool = false,
      @supports_mid_convo_system_messages : Bool = false,
      @supports_mid_convo_tool_changes : Bool = false,
      @supports_mid_convo_effort : Bool = false,
      @allowed_fallback_models : Array(FallbackModel) = [] of FallbackModel,
      @requires_tool_result_name : Bool = false,
      @requires_assistant_after_tool_result : Bool = false,
    )
    end
  end

  struct Model
    include JSON::Serializable

    getter id                                : String
    getter name                              : String
    getter provider                          : String
    getter base_url                          : String
    getter api                               : ApiKind
    getter input                             : Array(InputKind)
    getter context_window                    : Int32
    getter max_tokens                        : Int32
    getter reasoning                         : Bool
    getter cost                              : ModelCost
    getter thinking_level_map                : Hash(String, String?)
    getter prompt_cache                      : Bool
    getter sampling_params                   : Hash(String, JSON::Any)?
    getter compat                            : Compat
    getter sampling_params_by_thinking_level : Hash(String, Hash(String, JSON::Any))?

    def initialize(
      @id : String,
      @name : String,
      @provider : String,
      @base_url : String,
      @api : ApiKind,
      @input : Array(InputKind),
      @context_window : Int32,
      @max_tokens : Int32,
      @reasoning : Bool,
      @cost : ModelCost,
      @thinking_level_map : Hash(String, String?) = Hash(String, String?).new,
      @prompt_cache : Bool = false,
      @sampling_params : Hash(String, JSON::Any)? = nil,
      @compat : Compat = Compat.new,
      @sampling_params_by_thinking_level : Hash(String, Hash(String, JSON::Any))? = nil,
    )
    end
  end

  struct Context
    include JSON::Serializable

    getter system_prompt : String?
    getter messages      : Array(Message)
    getter tools         : Array(Tool)

    def initialize(@messages : Array(Message), @system_prompt : String? = nil, @tools : Array(Tool) = [] of Tool)
    end
  end

  struct StreamHooks
    include JSON::Serializable

    @[JSON::Field(ignore: true)]
    getter on_payload : Proc(JSON::Any, Model, JSON::Any)?
    @[JSON::Field(ignore: true)]
    getter on_response : Proc(Int32, HTTP::Headers, Nil)?
    @[JSON::Field(ignore: true)]
    getter on_event : Proc(StreamEvent, Nil)?

    def initialize(
      @on_payload : Proc(JSON::Any, Model, JSON::Any)? = nil,
      @on_response : Proc(Int32, HTTP::Headers, Nil)? = nil,
      @on_event : Proc(StreamEvent, Nil)? = nil,
    )
    end
  end

  struct StreamOptions
    include JSON::Serializable

    getter max_tokens       : Int32?
    getter temperature      : Float64?
    getter thinking_level   : String?
    getter thinking_enabled : Bool?
    getter effort           : String?
    getter thinking_display : String?
    getter tool_choice      : String?
    getter headers          : Hash(String, String)?
    @[JSON::Field(converter: LLM::AI::SymbolName)]
    getter cache_retention : Symbol?
    getter max_retries     : Int32
    getter timeout_ms      : Int32?
    getter user_id         : String?
    @[JSON::Field(ignore: true)]
    getter hooks           : StreamHooks?
    getter sampling_params : Hash(String, JSON::Any)?

    def initialize(
      @max_tokens : Int32? = nil,
      @temperature : Float64? = nil,
      @thinking_level : String? = nil,
      @thinking_enabled : Bool? = nil,
      @effort : String? = nil,
      @thinking_display : String? = nil,
      @tool_choice : String? = nil,
      @headers : Hash(String, String)? = nil,
      @cache_retention : Symbol? = nil,
      @max_retries : Int32 = 0,
      @timeout_ms : Int32? = nil,
      @user_id : String? = nil,
      @hooks : StreamHooks? = nil,
      @sampling_params : Hash(String, JSON::Any)? = nil,
    )
    end
  end
end
