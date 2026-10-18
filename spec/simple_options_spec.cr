# spec/simple_options_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def model(max_tokens : Int32, reasoning : Bool = true,
                  thinking_level_map : Hash(String, String?) = Hash(String, String?).new,
                  force_adaptive : Bool = false,
                  sampling_params : Hash(String, JSON::Any)? = nil,
                  by_level : Hash(String, Hash(String, JSON::Any))? = nil) : LLM::AI::Model
  compat = LLM::AI::Compat.new(force_adaptive_thinking: force_adaptive)
  LLM::AI::Model.new("m", "m", "p", "https://x", LLM::AI::ApiKind::OpenaiCompletions,
    [LLM::AI::InputKind::Text], 1000, max_tokens, reasoning,
    LLM::AI::ModelCost.new(1.0, 1.0, 0.1, 1.0, nil),
    thinking_level_map, false, sampling_params, compat, by_level)
end

describe LLM::AI::SimpleOptions do
  it "resolves default thinking budgets per level" do
    LLM::AI::SimpleOptions.resolve(model(2000), LLM::AI::StreamOptions.new(thinking_level: "high")).thinking_budget_tokens.should eq 16384
    LLM::AI::SimpleOptions.resolve(model(2000), LLM::AI::StreamOptions.new(thinking_level: "max")).thinking_budget_tokens.should eq 16384
    LLM::AI::SimpleOptions.resolve(model(2000), LLM::AI::StreamOptions.new(thinking_level: "minimal")).thinking_budget_tokens.should eq 1024
    LLM::AI::SimpleOptions.resolve(model(2000, reasoning: false), LLM::AI::StreamOptions.new).thinking_enabled.should be_false
  end

  it "expands max_tokens for the thinking budget" do
    resolved = LLM::AI::SimpleOptions.resolve(model(20000), LLM::AI::StreamOptions.new(max_tokens: 2000, thinking_level: "high"))
    resolved.max_tokens.should eq 18384
    resolved.thinking_budget_tokens.should eq 16384
  end

  it "clamps the budget to the model ceiling minus 1024" do
    resolved = LLM::AI::SimpleOptions.resolve(model(2000), LLM::AI::StreamOptions.new(max_tokens: 2000, thinking_level: "high"))
    resolved.max_tokens.should eq 2000
    resolved.thinking_budget_tokens.should eq 976
  end

  it "defaults budget to 1024 when thinking is enabled without a level" do
    resolved = LLM::AI::SimpleOptions.resolve(model(2000), LLM::AI::StreamOptions.new(thinking_enabled: true))
    resolved.thinking_budget_tokens.should eq 1024
    resolved.effort.should be_nil
    adaptive = LLM::AI::SimpleOptions.resolve(model(2000, force_adaptive: true), LLM::AI::StreamOptions.new(thinking_enabled: true))
    adaptive.effort.should eq "high"
  end

  it "maps thinking level to effort through thinking_level_map" do
    resolved = LLM::AI::SimpleOptions.resolve(
      model(2000, thinking_level_map: {"high" => "high".as(String?)}),
      LLM::AI::StreamOptions.new(thinking_level: "high"),
    )
    resolved.effort.should eq "high"
  end

  it "merges sampling params model → level → request" do
    target = model(2000,
      sampling_params: {"temperature" => JSON::Any.new(0.1)},
      by_level: {"high" => {"temperature" => JSON::Any.new(0.2), "top_p" => JSON::Any.new(0.9)}})
    resolved = LLM::AI::SimpleOptions.resolve(
      target,
      LLM::AI::StreamOptions.new(thinking_level: "high", sampling_params: {"temperature" => JSON::Any.new(0.3)}),
    )
    resolved.sampling_params.should eq({
      "temperature" => JSON::Any.new(0.3),
      "top_p"       => JSON::Any.new(0.9),
    })
  end
end
