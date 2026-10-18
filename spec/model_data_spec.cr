# spec/model_data_spec.cr
require "./spec_helper"
require "../src/llm-ai"

describe LLM::AI::ModelData do
  it "loads all four catalogs" do
    {"deepseek", "kimi-coding", "moonshot", "anthropic"}.each do |provider_id|
      models = LLM::AI::ModelData.load(provider_id)
      models.size.should be > 0
      models.each do |model|
        model.provider.should eq provider_id
        model.base_url.should_not be_empty
        model.context_window.should be > 0
        model.max_tokens.should be > 0
        model.cost.input.should be > 0
        model.cost.output.should be > 0
      end
    end
  end

  it "applies deepseek compat flags" do
    LLM::AI::ModelData.load("deepseek").each do |model|
      model.api.should eq LLM::AI::ApiKind::OpenaiCompletions
      model.compat.max_tokens_field.should eq :max_tokens
      model.compat.thinking_format.should eq :deepseek
      model.compat.requires_reasoning_content_on_assistant_messages.should be_true
    end
  end

  it "applies kimi compat flags" do
    (LLM::AI::ModelData.load("kimi-coding") + LLM::AI::ModelData.load("moonshot")).each do |model|
      model.api.should eq LLM::AI::ApiKind::OpenaiCompletions
      model.compat.max_tokens_field.should eq :max_completion_tokens
      model.compat.supports_store.should be_true
    end
  end

  it "uses anthropic_messages api for anthropic models" do
    LLM::AI::ModelData.load("anthropic").each do |model|
      model.api.should eq LLM::AI::ApiKind::AnthropicMessages
    end
  end

  it "marks the 5.5 generation as adaptive thinking" do
    models = LLM::AI::ModelData.load("anthropic")
    adaptive = models.select(&.compat.force_adaptive_thinking)
    adaptive.map(&.id).should eq ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
    adaptive.each do |model|
      model.thinking_level_map["off"]?.should be_nil
      model.thinking_level_map.has_key?("off").should be_true
    end
  end

  it "raises on unknown provider" do
    expect_raises(LLM::AI::ModelData::Error) { LLM::AI::ModelData.load("nope") }
  end

  it "loads corrected 5.5 thinking maps and compat flags" do
    models = LLM::AI::ModelData.load("anthropic").to_h { |model| {model.id, model} }
    {"claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"}.each do |id|
      model = models[id]
      model.thinking_level_map.should eq({"off" => nil, "minimal" => nil, "low" => "low", "medium" => "medium", "high" => "high", "xhigh" => "xhigh", "max" => "max"})
      model.compat.force_adaptive_thinking.should be_true
      model.compat.supports_mid_convo_effort.should be_true
      model.compat.supports_mid_convo_system_messages.should be_true
      model.compat.supports_mid_convo_tool_changes.should be_true
    end
    models["claude-opus-5-5"].compat.supports_temperature.should be_true
    models["claude-sonnet-5-5"].compat.supports_temperature.should be_false
    models["claude-haiku-5-5"].compat.supports_temperature.should be_false
    models["claude-opus-4-8"].compat.supports_mid_convo_system_messages.should be_true
    models["claude-opus-4-8"].compat.supports_temperature.should be_false
    models["claude-opus-4-7"].compat.supports_temperature.should be_false
  end

  it "parses allowed_fallback_models with cost and tiers" do
    compat = LLM::AI::ModelData.build_compat(JSON.parse(<<-JSON
      {
        "allowed_fallback_models": [
          {"provider": "anthropic", "model": "claude-opus-4-8", "cost": {"input": 5.0, "output": 25.0, "cache_read": 0.5, "cache_write": 6.25, "cache_write_1h": 10.0}},
          {"provider": "deepseek", "model": "deepseek-chat", "cost": {"input": 1.0, "output": 2.0, "cache_read": 0.1, "cache_write": 0.2, "tiers": [{"above": 100000, "cost": {"input": 0.5, "output": 1.0, "cache_read": 0.05, "cache_write": 0.1}}]}}
        ]
      }
      JSON
    ))
    compat.allowed_fallback_models.size.should eq 2
    first = compat.allowed_fallback_models[0]
    first.provider.should eq "anthropic"
    first.model.should eq "claude-opus-4-8"
    first.cost.input.should eq 5.0
    first.cost.output.should eq 25.0
    first.cost.cache_read.should eq 0.5
    first.cost.cache_write.should eq 6.25
    first.cost.cache_write_1h.should eq 10.0
    first.cost.tiers.should be_empty
    second = compat.allowed_fallback_models[1]
    second.cost.tiers.size.should eq 1
    second.cost.tiers[0].above.should eq 100000
    second.cost.tiers[0].cost.input.should eq 0.5
    second.cost.tiers[0].cost.output.should eq 1.0
    second.cost.cache_write_1h.should be_nil
  end

  it "defaults every compat flag when absent" do
    compat = LLM::AI::ModelData.build_compat(JSON.parse(%({})))
    compat.max_tokens_field.should eq :max_completion_tokens
    compat.thinking_format.should be_nil
    compat.requires_reasoning_content_on_assistant_messages.should be_false
    compat.supports_finish_reason.should be_true
    compat.supports_usage_in_streaming.should be_true
    compat.supports_store.should be_true
    compat.supports_developer_role.should be_false
    compat.supports_mid_convo_tool_additions.should be_false
    compat.supports_temperature.should be_true
    compat.supports_eager_tool_input_streaming.should be_true
    compat.supports_long_cache_retention.should be_true
    compat.supports_cache_control_on_tools.should be_true
    compat.supports_strict_tools.should be_false
    compat.allow_empty_signature.should be_false
    compat.force_adaptive_thinking.should be_false
    compat.supports_mid_convo_system_messages.should be_false
    compat.supports_mid_convo_tool_changes.should be_false
    compat.supports_mid_convo_effort.should be_false
    compat.allowed_fallback_models.should be_empty
    compat.requires_tool_result_name.should be_false
    compat.requires_assistant_after_tool_result.should be_false
  end

  it "round-trips every compat field through JSON" do
    compat = LLM::AI::ModelData.build_compat(JSON.parse(%({
      "max_tokens_field": "max_tokens",
      "thinking_format": "deepseek",
      "requires_reasoning_content_on_assistant_messages": true,
      "supports_finish_reason": false,
      "supports_usage_in_streaming": false,
      "supports_store": false,
      "supports_developer_role": true,
      "supports_mid_convo_tool_additions": true,
      "supports_temperature": false,
      "supports_eager_tool_input_streaming": false,
      "supports_long_cache_retention": false,
      "supports_cache_control_on_tools": false,
      "supports_strict_tools": true,
      "allow_empty_signature": true,
      "force_adaptive_thinking": true,
      "supports_mid_convo_system_messages": true,
      "supports_mid_convo_tool_changes": true,
      "supports_mid_convo_effort": true,
      "allowed_fallback_models": [{"provider": "anthropic", "model": "claude-opus-4-8", "cost": {"input": 5.0, "output": 25.0, "cache_read": 0.5, "cache_write": 6.25, "cache_write_1h": 10.0}}],
      "requires_tool_result_name": true,
      "requires_assistant_after_tool_result": true
    })))
    compat.max_tokens_field.should eq :max_tokens
    compat.thinking_format.should eq :deepseek
    compat.requires_reasoning_content_on_assistant_messages.should be_true
    compat.supports_finish_reason.should be_false
    compat.supports_usage_in_streaming.should be_false
    compat.supports_store.should be_false
    compat.supports_developer_role.should be_true
    compat.supports_mid_convo_tool_additions.should be_true
    compat.supports_temperature.should be_false
    compat.supports_eager_tool_input_streaming.should be_false
    compat.supports_long_cache_retention.should be_false
    compat.supports_cache_control_on_tools.should be_false
    compat.supports_strict_tools.should be_true
    compat.allow_empty_signature.should be_true
    compat.force_adaptive_thinking.should be_true
    compat.supports_mid_convo_system_messages.should be_true
    compat.supports_mid_convo_tool_changes.should be_true
    compat.supports_mid_convo_effort.should be_true
    compat.allowed_fallback_models.size.should eq 1
    compat.allowed_fallback_models[0].provider.should eq "anthropic"
    compat.allowed_fallback_models[0].model.should eq "claude-opus-4-8"
    compat.allowed_fallback_models[0].cost.input.should eq 5.0
    compat.allowed_fallback_models[0].cost.cache_write_1h.should eq 10.0
    compat.requires_tool_result_name.should be_true
    compat.requires_assistant_after_tool_result.should be_true
    LLM::AI::Compat.from_json(compat.to_json).to_json.should eq compat.to_json
  end

  it "raises ModelData::Error naming the field for bad compat values" do
    expect_raises(LLM::AI::ModelData::Error, "invalid max_tokens_field") do
      LLM::AI::ModelData.build_compat(JSON.parse(%({"max_tokens_field": "bogus"})))
    end
    expect_raises(LLM::AI::ModelData::Error, "invalid supports_store") do
      LLM::AI::ModelData.build_compat(JSON.parse(%({"supports_store": "yes"})))
    end
    expect_raises(LLM::AI::ModelData::Error, "invalid allowed_fallback_models") do
      LLM::AI::ModelData.build_compat(JSON.parse(%({"allowed_fallback_models": [{"provider": "anthropic", "model": "m", "cost": {"input": 1.0}}]})))
    end
  end
end
