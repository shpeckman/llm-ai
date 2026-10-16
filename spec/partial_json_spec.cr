# spec/partial_json_spec.cr
require "./spec_helper"
require "../src/llm-ai"

describe LLM::AI::PartialJson do
  it "completes a truncated string" do
    LLM::AI::PartialJson.parse(%({"a":"fi))["a"].should eq("fi")
  end

  it "completes a truncated object" do
    value = LLM::AI::PartialJson.parse(%({"name":"tool","arguments":{"city":"pari))
    value.should eq JSON.parse(%({"name":"tool","arguments":{"city":"pari"}}))
  end

  it "completes a truncated nested array" do
    LLM::AI::PartialJson.parse("[1,2,").should eq JSON.parse("[1,2]")
  end

  it "returns {} for empty input" do
    LLM::AI::PartialJson.parse("").as_h.empty?.should be_true
  end

  it "returns completed text" do
    LLM::AI::PartialJson.complete(%({"a":"fi)).should eq %({"a":"fi"})
    LLM::AI::PartialJson.complete("[1,2,").should eq "[1,2]"
  end

  it "returns {} for garbage input" do
    LLM::AI::PartialJson.parse("not json").as_h.empty?.should be_true
  end
end
