# spec/transform_messages_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def assistant(*blocks : LLM::AI::ContentBlock, stop_reason : LLM::AI::StopReason = LLM::AI::StopReason::Stop) : LLM::AI::AssistantMessage
  LLM::AI::AssistantMessage.new(blocks.map { |block| block.as(LLM::AI::ContentBlock) }.to_a, "p", "m", Time.utc, stop_reason: stop_reason)
end

private def assistant_from(provider : String, model_id : String, *blocks : LLM::AI::ContentBlock) : LLM::AI::AssistantMessage
  LLM::AI::AssistantMessage.new(blocks.map { |block| block.as(LLM::AI::ContentBlock) }.to_a, provider, model_id, Time.utc)
end

private def user_text(text : String) : LLM::AI::UserMessage
  LLM::AI::UserMessage.new([LLM::AI::TextContent.new(text)] of LLM::AI::ContentBlock, Time.utc)
end

private def model(reasoning : Bool, vision : Bool = true) : LLM::AI::Model
  input = vision ? [LLM::AI::InputKind::Text, LLM::AI::InputKind::Image] : [LLM::AI::InputKind::Text]
  LLM::AI::Model.new("m", "m", "p", "https://x", LLM::AI::ApiKind::OpenaiCompletions,
    input, 1000, 1000, reasoning, LLM::AI::ModelCost.new(1.0, 1.0, 0.1, 1.0, nil))
end

private def compat_model(compat : LLM::AI::Compat) : LLM::AI::Model
  LLM::AI::Model.new("m", "m", "p", "https://x", LLM::AI::ApiKind::OpenaiCompletions,
    [LLM::AI::InputKind::Text], 1000, 1000, false, LLM::AI::ModelCost.new(1.0, 1.0, 0.1, 1.0, nil), compat: compat)
end

private def tool(name : String) : LLM::AI::Tool
  LLM::AI::Tool.new(name, "#{name} tool", JSON.parse(%({"type":"object"})))
end

private def tool_transcript : Array(LLM::AI::Message)
  [
    LLM::AI::SystemMessage.new("lead", Time.utc, tools_added: [tool("a")]),
    user_text("one"),
    LLM::AI::SystemMessage.new("", Time.utc, tools_added: [tool("b")]),
    user_text("two"),
    LLM::AI::SystemMessage.new("", Time.utc, tools_removed: [LLM::AI::ToolReference.new("a")]),
    user_text("three"),
    LLM::AI::SystemMessage.new("", Time.utc, tools_added: [tool("c")]),
    user_text("four"),
  ] of LLM::AI::Message
end

private def tool_fields(context : LLM::AI::Context) : Array(Tuple(Array(String)?, Array(String)?))
  context.messages.select(LLM::AI::SystemMessage).map do |message|
    {message.tools_added.try(&.map(&.name)), message.tools_removed.try(&.map(&.name))}
  end
end

describe LLM::AI::Transform do
  it "sends the current transcript tools at the top level when the model has no mid-conversation tools" do
    normalized = LLM::AI::Transform.normalize(LLM::AI::Context.new(tool_transcript), compat_model(LLM::AI::Compat.new))
    normalized.tools.map(&.name).should eq ["b", "c"]
    tool_fields(normalized).should eq [{nil, nil}, {nil, nil}, {nil, nil}, {nil, nil}]
  end

  it "folds tool changes up to the last removal for addition-only models" do
    compat = LLM::AI::Compat.new(supports_mid_convo_system_messages: true, supports_mid_convo_tool_additions: true)
    normalized = LLM::AI::Transform.normalize(LLM::AI::Context.new(tool_transcript), compat_model(compat))
    normalized.tools.map(&.name).should eq ["b"]
    tool_fields(normalized).should eq [{nil, nil}, {nil, nil}, {nil, nil}, {["c"], nil}]
  end

  it "keeps every later tool change in place for models with native tool changes" do
    compat = LLM::AI::Compat.new(supports_mid_convo_system_messages: true, supports_mid_convo_tool_changes: true)
    normalized = LLM::AI::Transform.normalize(LLM::AI::Context.new(tool_transcript), compat_model(compat))
    normalized.tools.map(&.name).should eq ["a"]
    tool_fields(normalized).should eq [{nil, nil}, {["b"], nil}, {nil, ["a"]}, {["c"], nil}]
  end

  it "treats context tools as the initial declaration" do
    messages = [user_text("hi"), LLM::AI::SystemMessage.new("", Time.utc, tools_added: [tool("b")])] of LLM::AI::Message
    plain = LLM::AI::Transform.normalize(LLM::AI::Context.new(messages, "prompt", [tool("a")]), compat_model(LLM::AI::Compat.new))
    plain.system_prompt.should eq "prompt"
    plain.tools.map(&.name).should eq ["a", "b"]
    compat = LLM::AI::Compat.new(supports_mid_convo_system_messages: true, supports_mid_convo_tool_additions: true)
    additive = LLM::AI::Transform.normalize(LLM::AI::Context.new(messages, "prompt", [tool("a")]), compat_model(compat))
    additive.tools.map(&.name).should eq ["a"]
    tool_fields(additive).should eq [{["b"], nil}]
  end

  it "keeps tool result details and usage" do
    call = LLM::AI::ToolCall.new("t1", "lookup", JSON.parse("{}"))
    usage = LLM::AI::Usage.new(1, 2, 0, 0, 3, LLM::AI::UsageCost.new(0.0, 0.0, 0.0, 0.0, 0.0))
    result = LLM::AI::ToolResultMessage.new("t1", "lookup", [LLM::AI::TextContent.new("ok")] of LLM::AI::ContentBlock, Time.utc,
      details: JSON.parse(%({"path":"/tmp"})), usage: usage)
    context = LLM::AI::Context.new([assistant(call), result] of LLM::AI::Message)
    normalized = LLM::AI::Transform.normalize(context, model(true)).messages[1].as(LLM::AI::ToolResultMessage)
    normalized.details.should eq JSON.parse(%({"path":"/tmp"}))
    normalized.usage.should eq usage
  end

  it "drops aborted and errored assistant turns" do
    context = LLM::AI::Context.new([
      user_text("hi"),
      assistant(LLM::AI::TextContent.new("bad"), stop_reason: LLM::AI::StopReason::Error),
      assistant(LLM::AI::TextContent.new("aborted"), stop_reason: LLM::AI::StopReason::Aborted),
      assistant(LLM::AI::TextContent.new("good")),
    ] of LLM::AI::Message)
    normalized = LLM::AI::Transform.normalize(context, model(true))
    normalized.messages.size.should eq 2
    normalized.messages[1].as(LLM::AI::AssistantMessage).content.should eq [LLM::AI::TextContent.new("good")]
  end

  it "converts thinking to text for non-reasoning targets" do
    message = assistant(LLM::AI::ThinkingContent.new("hmm", "sig"))
    context = LLM::AI::Context.new([message] of LLM::AI::Message)
    converted = LLM::AI::Transform.normalize(context, model(false)).messages[0].as(LLM::AI::AssistantMessage)
    converted.content[0].should eq LLM::AI::TextContent.new("hmm")
    kept = LLM::AI::Transform.normalize(context, model(true)).messages[0].as(LLM::AI::AssistantMessage)
    kept.content[0].should eq LLM::AI::ThinkingContent.new("hmm", "sig")
  end

  it "inserts a synthetic error tool result for orphaned tool calls" do
    call = LLM::AI::ToolCall.new("t1", "lookup", JSON.parse("{}"), nil, nil, nil)
    context = LLM::AI::Context.new([assistant(call)] of LLM::AI::Message)
    normalized = LLM::AI::Transform.normalize(context, model(true))
    normalized.messages.size.should eq 2
    result = normalized.messages[1].should be_a(LLM::AI::ToolResultMessage)
    result.tool_call_id.should eq "t1"
    result.is_error.should be_true
    result.content.should eq [LLM::AI::TextContent.new("No result provided")]
  end

  it "normalizes tool call ids" do
    call = LLM::AI::ToolCall.new("a b!c" + "x" * 100, "lookup", JSON.parse("{}"), nil, nil, nil)
    context = LLM::AI::Context.new([assistant(call)] of LLM::AI::Message)
    normalized = LLM::AI::Transform.normalize(context, model(true))
    first = normalized.messages[0].as(LLM::AI::AssistantMessage)
    first.content[0].as(LLM::AI::ToolCall).id.should eq "a_b_c" + "x" * (64 - 5)
  end

  it "replaces images for non-vision targets" do
    message = LLM::AI::UserMessage.new([LLM::AI::ImageContent.new("abc", "image/png")] of LLM::AI::ContentBlock, Time.utc)
    context = LLM::AI::Context.new([message] of LLM::AI::Message)
    normalized = LLM::AI::Transform.normalize(context, model(true, vision: false))
    normalized.messages[0].as(LLM::AI::UserMessage).content.as(Array(LLM::AI::ContentBlock))[0].should eq(
      LLM::AI::TextContent.new("(image omitted: model does not support images)")
    )
  end

  it "inserts synthetic tool results before the next user turn" do
    call = LLM::AI::ToolCall.new("t1", "lookup", JSON.parse("{}"), nil, nil, nil)
    context = LLM::AI::Context.new([assistant(call), user_text("hi")] of LLM::AI::Message)
    normalized = LLM::AI::Transform.normalize(context, model(true))
    normalized.messages.size.should eq 3
    normalized.messages[0].should be_a(LLM::AI::AssistantMessage)
    result = normalized.messages[1].should be_a(LLM::AI::ToolResultMessage)
    result.tool_call_id.should eq "t1"
    normalized.messages[2].should be_a(LLM::AI::UserMessage)
  end

  it "remaps result ids to match normalized call ids" do
    call = LLM::AI::ToolCall.new("a b!c", "lookup", JSON.parse("{}"), nil, nil, nil)
    result = LLM::AI::ToolResultMessage.new(
      "a b!c", "lookup", [LLM::AI::TextContent.new("ok")] of LLM::AI::ContentBlock, Time.utc
    )
    context = LLM::AI::Context.new([assistant(call), result] of LLM::AI::Message)
    normalized = LLM::AI::Transform.normalize(context, model(true))
    normalized.messages.size.should eq 2
    normalized.messages[0].as(LLM::AI::AssistantMessage).content[0].as(LLM::AI::ToolCall).id.should eq "a_b_c"
    normalized.messages[1].as(LLM::AI::ToolResultMessage).tool_call_id.should eq "a_b_c"
  end

  it "keeps thinking signatures for the same model and strips them cross-model" do
    kept = LLM::AI::Transform.normalize(
      LLM::AI::Context.new([assistant(LLM::AI::ThinkingContent.new("hmm", "sig"))] of LLM::AI::Message),
      model(true),
    ).messages[0].as(LLM::AI::AssistantMessage)
    kept.content[0].should eq LLM::AI::ThinkingContent.new("hmm", "sig")

    stripped = LLM::AI::Transform.normalize(
      LLM::AI::Context.new([assistant_from("other", "other", LLM::AI::ThinkingContent.new("hmm", "sig"))] of LLM::AI::Message),
      model(true),
    ).messages[0].as(LLM::AI::AssistantMessage)
    stripped.content[0].should eq LLM::AI::ThinkingContent.new("hmm")
  end

  it "drops redacted thinking cross-model and keeps it for the same model" do
    redacted = LLM::AI::ThinkingContent.new("", "sig", true)
    dropped = LLM::AI::Transform.normalize(
      LLM::AI::Context.new([assistant_from("other", "other", redacted)] of LLM::AI::Message),
      model(true),
    ).messages[0].as(LLM::AI::AssistantMessage)
    dropped.content.should be_empty

    kept = LLM::AI::Transform.normalize(
      LLM::AI::Context.new([assistant(redacted)] of LLM::AI::Message),
      model(true),
    ).messages[0].as(LLM::AI::AssistantMessage)
    kept.content.should eq [redacted]
  end
end
