# spec/scripted_faux_spec.cr
require "./spec_helper"
require "../src/llm-ai"

alias Faux = LLM::AI::FauxProvider

private def models_with(faux : Faux::Scripted) : LLM::AI::Models
  models = LLM::AI::Models.new(LLM::AI::FileCredentialStore.new(Path[Dir.tempdir, "llm-ai-faux-#{Random::Secure.hex(4)}.json"]), LLM::AI::Auth::AuthContext.new(->(_name : String) { nil.as(String?) }, ->(_path : String) { false }))
  models.register(faux.provider)
  models
end

private def context(text : String = "hi") : LLM::AI::Context
  LLM::AI::Context.new([LLM::AI::UserMessage.new(text, Time.utc)] of LLM::AI::Message)
end

describe Faux do
  it "builds scripted messages" do
    message = Faux.assistant_message([Faux.text("a"), Faux.tool_call("calc", {expression: "1+1"}, id: "c1")] of LLM::AI::ContentBlock, stop_reason: :tool_use)
    message.stop_reason.should eq LLM::AI::StopReason::ToolUse
    message.content[1].should eq LLM::AI::ToolCall.new("c1", "calc", JSON.parse(%({"expression":"1+1"})))
    Faux.assistant_message("hi").content.should eq [LLM::AI::TextContent.new("hi")]
  end

  it "streams scripted responses with deltas and estimated usage" do
    faux = Faux.scripted(token_size: 1..1)
    faux.responses = [Faux.assistant_message([Faux.thinking("ponder"), Faux.text("hello world"), Faux.tool_call("calc", {x: 1}, id: "t")] of LLM::AI::ContentBlock, stop_reason: :tool_use)] of Faux::ResponseStep
    events = [] of LLM::AI::StreamEvent
    stream = models_with(faux).stream(faux.model, context)
    stream.each { |event| events << event }
    kinds = events.map(&.class.name.split("::").last)
    kinds.first.should eq "Start"
    kinds.should contain "ThinkingDelta"
    kinds.should contain "ToolCallEnd"
    kinds.last.should eq "Done"
    events.select(LLM::AI::StreamEvent::TextDelta).map(&.text).join.should eq "hello world"
    events.select(LLM::AI::StreamEvent::TextDelta).first.text.should eq "hell"
    result = stream.result
    result.provider.should eq "faux"
    result.model.should eq "faux-1"
    result.content[2].should eq LLM::AI::ToolCall.new("t", "calc", JSON.parse(%({"x":1})))
    result.usage.not_nil!.input.should eq (("user:hi".size) / 4).ceil.to_i
    result.usage.not_nil!.output.should be > 0
    faux.state.call_count.should eq 1
    faux.pending_response_count.should eq 0
  end

  it "calls response factories with the request" do
    faux = Faux.scripted(models: [Faux::ModelDefinition.new("faux-reasoning", reasoning: true)])
    faux.append_response do |request, options, state, model|
      user = request.messages.last.as(LLM::AI::UserMessage).content.as(String)
      Faux.assistant_message("#{user}/#{options.session_id}/#{state.call_count}/#{model.id}")
    end
    message = models_with(faux).chat(faux.model("faux-reasoning").not_nil!, context("ping"), LLM::AI::StreamOptions.new(session_id: "s"))
    message.content.should eq [LLM::AI::TextContent.new("ping/s/1/faux-reasoning")]
    faux.model("missing").should be_nil
    faux.model.reasoning.should be_true
  end

  it "reports an error when no responses are queued or a script stops with an error" do
    faux = Faux.scripted
    expect_raises(LLM::AI::ModelsError, "No more faux responses queued") { models_with(faux).chat(faux.model, context) }
    faux.responses = [Faux.assistant_message("x", stop_reason: :error, error_message: "scripted failure")] of Faux::ResponseStep
    expect_raises(LLM::AI::ModelsError, "scripted failure") { models_with(faux).chat(faux.model, context) }
  end

  it "aborts between chunks" do
    faux = Faux.scripted(tokens_per_second: 20.0, token_size: 2..2)
    faux.responses = [Faux.assistant_message("one two three four five six seven eight nine ten")] of Faux::ResponseStep
    abort = LLM::AI::AbortHandle.new
    stream = models_with(faux).stream(faux.model, context, nil, abort)
    spawn { sleep 30.milliseconds; abort.abort }
    result = stream.result
    result.stop_reason.should eq LLM::AI::StopReason::Aborted
    result.error_message.should eq "Request was aborted"
    result.content.size.should eq 1
  end

  it "reads cache hits from the prompt shared with the previous request of a session" do
    faux = Faux.scripted
    faux.responses = [Faux.assistant_message("a"), Faux.assistant_message("b")] of Faux::ResponseStep
    models = models_with(faux)
    options = LLM::AI::StreamOptions.new(session_id: "session")
    first = models.chat(faux.model, context("same prefix"), options).usage.not_nil!
    first.cache_read.should eq 0
    first.cache_write.should eq first.input
    second = models.chat(faux.model, context("same prefix, longer"), options).usage.not_nil!
    second.cache_read.should eq ("user:same prefix".size / 4).ceil.to_i
  end
end
