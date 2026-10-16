# spec/abort_spec.cr
require "./spec_helper"
require "../src/llm-ai"

describe LLM::AI::AbortHandle do
  it "flags after abort" do
    handle = LLM::AI::AbortHandle.new
    handle.aborted?.should be_false
    handle.abort
    handle.aborted?.should be_true
  end

  it "is safe to abort twice" do
    handle = LLM::AI::AbortHandle.new
    handle.abort
    handle.abort
    handle.aborted?.should be_true
  end
end

describe LLM::AI::AbortError do
  it "constructs and raises" do
    LLM::AI::AbortError.new.should be_a(Exception)
    expect_raises(LLM::AI::AbortError) { raise LLM::AI::AbortError.new }
  end
end
