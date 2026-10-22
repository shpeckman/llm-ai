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

  it "records the first reason and raises it from throw_if_aborted" do
    handle = LLM::AI::AbortHandle.new
    handle.reason.should be_nil
    handle.throw_if_aborted
    handle.abort("stop")
    handle.abort("again")
    handle.reason.not_nil!.message.should eq "stop"
    handle.reason.should be_a(LLM::AI::AbortError)
    expect_raises(LLM::AI::AbortError, "stop") { handle.throw_if_aborted }
  end

  it "defaults the reason to an AbortError" do
    handle = LLM::AI::AbortHandle.new
    handle.abort
    handle.reason.not_nil!.message.should eq "The operation was aborted"
  end

  it "calls abort listeners once in registration order" do
    handle = LLM::AI::AbortHandle.new
    calls = [] of String
    handle.on_abort { |reason| calls << "first:#{reason.message}" }
    remove = handle.on_abort { |_| calls << "removed" }
    handle.on_abort { |_| calls << "second" }
    remove.call
    handle.abort("now")
    handle.abort("later")
    calls.should eq ["first:now", "second"]
  end

  it "ignores listeners registered after abort" do
    handle = LLM::AI::AbortHandle.new
    handle.abort
    called = false
    handle.on_abort { |_| called = true }.call
    called.should be_false
  end

  it "runs every listener and raises the first failure" do
    handle = LLM::AI::AbortHandle.new
    calls = [] of Int32
    handle.on_abort { |_| calls << 1; raise "boom" }
    handle.on_abort { |_| calls << 2 }
    expect_raises(Exception, "boom") { handle.abort }
    calls.should eq [1, 2]
    handle.aborted?.should be_true
  end
end

describe LLM::AI::AbortError do
  it "constructs and raises" do
    LLM::AI::AbortError.new.should be_a(Exception)
    expect_raises(LLM::AI::AbortError) { raise LLM::AI::AbortError.new }
  end
end
