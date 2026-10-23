# src/llm-ai/model_data.cr
module LLM::AI::ModelData
  class Error < Exception
  end

  private struct Entry
    include JSON::Serializable

    getter id : String
    getter name : String
    getter base_url : String
    getter api : ApiKind
    getter input : Array(InputKind)
    getter context_window : Int32
    getter max_tokens : Int32
    getter reasoning : Bool
    getter cost : JSON::Any
    getter thinking_level_map : Hash(String, String?)?
    getter prompt_cache : Bool?
    getter sampling_params : Hash(String, JSON::Any)?
    getter compat : JSON::Any?

    def initialize(@id, @name, @base_url, @api, @input, @context_window, @max_tokens, @reasoning, @cost,
                   @thinking_level_map = nil, @prompt_cache = nil, @sampling_params = nil, @compat = nil)
    end
  end

  def self.load(provider_id : String) : Array(Model)
    parse(provider_id).map { |entry| build_model(provider_id, entry) }
  rescue ex : JSON::ParseException | JSON::SerializableError | JSON::Error | KeyError | TypeCastError
    raise Error.new("invalid model data for provider #{provider_id}: #{ex.message}")
  end

  private def self.parse(provider_id : String) : Array(Entry)
    json = case provider_id
           when "deepseek"
             {{ read_file("#{__DIR__}/data/deepseek.json") }}
           when "deepseek-anthropic"
             {{ read_file("#{__DIR__}/data/deepseek-anthropic.json") }}
           when "deepseek-responses"
             {{ read_file("#{__DIR__}/data/deepseek-responses.json") }}
           when "kimi-coding"
             {{ read_file("#{__DIR__}/data/kimi-coding.json") }}
           when "moonshot", "kimi"
             {{ read_file("#{__DIR__}/data/moonshot.json") }}
           when "moonshot-anthropic"
             {{ read_file("#{__DIR__}/data/moonshot-anthropic.json") }}
           when "moonshot-responses"
             {{ read_file("#{__DIR__}/data/moonshot-responses.json") }}
           when "anthropic"
             {{ read_file("#{__DIR__}/data/anthropic.json") }}
           else
             raise Error.new("unknown provider: #{provider_id}")
           end
    Array(Entry).from_json(json)
  end

  private def self.build_model(provider_id : String, entry : Entry) : Model
    Model.new(
      entry.id, entry.name, provider_id, entry.base_url, entry.api, entry.input,
      entry.context_window, entry.max_tokens, entry.reasoning,
      build_cost(entry.cost),
      entry.thinking_level_map || Hash(String, String?).new,
      entry.prompt_cache || false,
      entry.sampling_params,
      build_compat(entry.compat),
    )
  rescue ex : Error
    raise Error.new("invalid model data for provider #{provider_id}: #{ex.message}")
  end

  private def self.build_cost(raw : JSON::Any) : ModelCost
    input = raw["input"].as_f
    output = raw["output"].as_f
    cache_read = raw["cache_read"].as_f
    cache_write = raw["cache_write"].as_f
    cache_write_1h = raw["cache_write_1h"]?.try(&.as_f)
    tiers = (raw["tiers"]? || JSON::Any.new([] of JSON::Any)).as_a.map do |tier|
      CostTier.new(tier["above"].as_i, build_cost(tier["cost"]))
    end
    ModelCost.new(input, output, cache_read, cache_write, cache_write_1h, tiers)
  end

  def self.build_compat(raw : JSON::Any?) : Compat
    return Compat.new if raw.nil?
    Compat.new(
      max_tokens_field: symbol_field(raw, "max_tokens_field", :max_completion_tokens),
      thinking_format: symbol_field?(raw, "thinking_format"),
      requires_reasoning_content_on_assistant_messages: bool_field(raw, "requires_reasoning_content_on_assistant_messages", false),
      supports_finish_reason: bool_field(raw, "supports_finish_reason", true),
      supports_usage_in_streaming: bool_field(raw, "supports_usage_in_streaming", true),
      supports_store: bool_field(raw, "supports_store", true),
      supports_developer_role: bool_field(raw, "supports_developer_role", false),
      supports_mid_convo_tool_additions: bool_field(raw, "supports_mid_convo_tool_additions", false),
      supports_temperature: bool_field(raw, "supports_temperature", true),
      supports_eager_tool_input_streaming: bool_field(raw, "supports_eager_tool_input_streaming", true),
      supports_long_cache_retention: bool_field(raw, "supports_long_cache_retention", true),
      supports_cache_control_on_tools: bool_field(raw, "supports_cache_control_on_tools", true),
      supports_strict_tools: bool_field(raw, "supports_strict_tools", false),
      allow_empty_signature: bool_field(raw, "allow_empty_signature", false),
      force_adaptive_thinking: bool_field(raw, "force_adaptive_thinking", false),
      supports_mid_convo_system_messages: bool_field(raw, "supports_mid_convo_system_messages", false),
      supports_mid_convo_tool_changes: bool_field(raw, "supports_mid_convo_tool_changes", false),
      supports_mid_convo_effort: bool_field(raw, "supports_mid_convo_effort", false),
      allowed_fallback_models: build_fallback_models(raw),
      requires_tool_result_name: bool_field(raw, "requires_tool_result_name", false),
      requires_assistant_after_tool_result: bool_field(raw, "requires_assistant_after_tool_result", false),
      supports_response_format: bool_field(raw, "supports_response_format", false),
      supports_stop: bool_field(raw, "supports_stop", false),
      supports_prediction: bool_field(raw, "supports_prediction", false),
      supports_logprobs: bool_field(raw, "supports_logprobs", false),
      supports_prompt_cache_key: bool_field(raw, "supports_prompt_cache_key", false),
      supports_safety_identifier: bool_field(raw, "supports_safety_identifier", false),
      supports_output_config_effort: bool_field(raw, "supports_output_config_effort", false),
      anthropic_auth_scheme: symbol_field(raw, "anthropic_auth_scheme", :x_api_key),
    )
  end

  private def self.build_fallback_models(raw : JSON::Any) : Array(FallbackModel)
    raw["allowed_fallback_models"]?.try do |value|
      value.as_a.map do |entry|
        FallbackModel.new(
          entry["provider"].as_s,
          entry["model"].as_s,
          build_cost(entry["cost"]),
        )
      end
    end || [] of FallbackModel
  rescue ex : KeyError | TypeCastError
    raise Error.new("invalid allowed_fallback_models: #{ex.message}")
  end

  private def self.symbol_field(raw : JSON::Any, key : String, default : Symbol) : Symbol
    raw[key]?.try { |value| parse_symbol(value.as_s) } || default
  rescue ex : Error | TypeCastError
    raise Error.new("invalid #{key}: #{ex.message}")
  end

  private def self.symbol_field?(raw : JSON::Any, key : String) : Symbol?
    raw[key]?.try { |value| parse_symbol(value.as_s) }
  rescue ex : Error | TypeCastError
    raise Error.new("invalid #{key}: #{ex.message}")
  end

  private def self.parse_symbol(value : String) : Symbol
    case value
    when "max_tokens"
      :max_tokens
    when "max_completion_tokens"
      :max_completion_tokens
    when "toggle"
      :toggle
    when "openai"
      :openai
    when "x_api_key"
      :x_api_key
    when "bearer"
      :bearer
    else
      raise Error.new("unknown symbol value: #{value}")
    end
  end

  private def self.bool_field(raw : JSON::Any, key : String, default : Bool) : Bool
    value = raw[key]?
    value.nil? ? default : value.as_bool
  rescue ex : TypeCastError
    raise Error.new("invalid #{key}: #{ex.message}")
  end
end
