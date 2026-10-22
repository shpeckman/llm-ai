# spec/pricing_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def anthropic_model
  LLM::AI::Model.new(
    "claude-opus-4-8", "Claude Opus 4.8", "anthropic",
    "https://api.anthropic.com", LLM::AI::ApiKind::AnthropicMessages,
    [LLM::AI::InputKind::Text], 1_000_000, 64_000, true,
    LLM::AI::ModelCost.new(5.0, 25.0, 0.5, 6.25, nil),
  )
end

private def usage(input : Int32, cache_write : Int32, cache_write_1h : Int32? = nil) : LLM::AI::Usage
  LLM::AI::Usage.new(input, 5, 0, cache_write, input + 5 + cache_write,
    LLM::AI::UsageCost.new(0.0, 0.0, 0.0, 0.0, 0.0), cache_write_1h)
end

describe LLM::AI::Pricing do
  it "prices the 1h portion at 2x input and the rest at the 5m rate" do
    model = anthropic_model
    cost = LLM::AI::Pricing.calculate(model, usage(input: 100, cache_write: 1_000_000, cache_write_1h: 400_000))
    cost.cache_write.should be_close(7.75, 1e-9)
  end

  it "bills cache_write_1h at 2x input when rate missing" do
    model = LLM::AI::Model.new(
      "m", "m", "p", "https://x", LLM::AI::ApiKind::AnthropicMessages,
      [LLM::AI::InputKind::Text], 1000, 1000, true,
      LLM::AI::ModelCost.new(3.0, 10.0, 0.3, 3.75, nil),
    )
    cost = LLM::AI::Pricing.calculate(model, usage(input: 0, cache_write: 1_000_000, cache_write_1h: 1_000_000))
    cost.cache_write.should be_close(6.0, 1e-9)
  end

  it "bills at the explicit 1h rate when present" do
    model = LLM::AI::Model.new(
      "m", "m", "p", "https://x", LLM::AI::ApiKind::AnthropicMessages,
      [LLM::AI::InputKind::Text], 1000, 1000, true,
      LLM::AI::ModelCost.new(5.0, 25.0, 0.5, 6.25, 10.0),
    )
    cost = LLM::AI::Pricing.calculate(model, usage(input: 0, cache_write: 1_000_000, cache_write_1h: 1_000_000))
    cost.cache_write.should be_close(10.0, 1e-9)
  end

  it "selects tiers by input_tokens_above" do
    tier = LLM::AI::CostTier.new(200_000, LLM::AI::ModelCost.new(0.5, 1.0, 0.05, 0.5, nil))
    model = LLM::AI::Model.new(
      "m", "m", "p", "https://x", LLM::AI::ApiKind::OpenaiCompletions,
      [LLM::AI::InputKind::Text], 1000, 1000, false,
      LLM::AI::ModelCost.new(1.0, 2.0, 0.1, 1.0, nil, [tier]),
    )
    above = LLM::AI::Pricing.calculate(model, usage(input: 300_000, cache_write: 0))
    above.input.should be_close(0.15, 1e-9)
    below = LLM::AI::Pricing.calculate(model, usage(input: 100_000, cache_write: 0))
    below.input.should be_close(0.1, 1e-9)
  end
end
