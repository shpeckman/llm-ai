# spec/transcript_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def tool(name : String, description : String = "#{name} tool") : LLM::AI::Tool
  LLM::AI::Tool.new(name, description, JSON.parse(%({"type":"object","properties":{}})))
end

private def system(content : String, sections : Hash(String, String?)? = nil, added : Array(LLM::AI::Tool)? = nil,
                   removed : Array(String)? = nil, timestamp : Int64 = 1) : LLM::AI::SystemMessage
  LLM::AI::SystemMessage.new(content, Time.unix_ms(timestamp), sections, added, removed.try(&.map { |name| LLM::AI::ToolReference.new(name) }))
end

private def model(compat : LLM::AI::Compat) : LLM::AI::Model
  LLM::AI::Model.new("m", "m", "p", "https://x", LLM::AI::ApiKind::OpenaiCompletions,
    [LLM::AI::InputKind::Text], 1000, 1000, false, LLM::AI::ModelCost.new(0.0, 0.0, 0.0, 0.0), compat: compat)
end

describe LLM::AI::Transcript do
  it "creates the leading system message only when a prompt or tools exist" do
    LLM::AI::Transcript.create_initial_system_message(nil, nil).should be_nil
    LLM::AI::Transcript.create_initial_system_message("", [] of LLM::AI::Tool).should be_nil
    prompt_only = LLM::AI::Transcript.create_initial_system_message("Be brief.", nil).not_nil!
    prompt_only.should eq LLM::AI::SystemMessage.new("Be brief.", Time.unix_ms(0))
    with_tools = LLM::AI::Transcript.create_initial_system_message(nil, [tool("echo")]).not_nil!
    with_tools.content.should eq ""
    with_tools.tools_added.not_nil!.map(&.name).should eq ["echo"]
  end

  it "replays tool deltas in order" do
    messages = [
      system("base", added: [tool("a"), tool("b")]),
      LLM::AI::UserMessage.new("hi", Time.utc),
      system("", added: [tool("c"), tool("a", "new a")], removed: ["b"]),
      system("", removed: ["a"]),
      system("", added: [tool("a", "newest a")]),
    ] of LLM::AI::Message
    current = LLM::AI::Transcript.current_tools(messages)
    current.map(&.name).should eq ["c", "a"]
    current[1].description.should eq "newest a"
  end

  it "keeps a redeclared tool in its first position" do
    messages = [system("", added: [tool("a"), tool("b")]), system("", added: [tool("a", "v2")])] of LLM::AI::Message
    LLM::AI::Transcript.current_tools(messages).map { |item| {item.name, item.description} }.should eq [{"a", "v2"}, {"b", "b tool"}]
  end

  it "replays content, sections, and tools into one system message" do
    messages = [
      system("You are helpful.", {"skills" => "<skills>a</skills>", "notes" => "n"} of String => String?, [tool("echo")], timestamp: 5),
      LLM::AI::UserMessage.new("hi", Time.utc),
      system("Extra rule.", {"skills" => "<skills>b</skills>", "notes" => nil} of String => String?),
    ] of LLM::AI::Message
    current = LLM::AI::Transcript.current_system_message(messages).not_nil!
    current.content.should eq "You are helpful.\n\nExtra rule."
    current.sections.should eq({"skills" => "<skills>b</skills>"})
    current.tools_added.not_nil!.map(&.name).should eq ["echo"]
    current.timestamp.should eq Time.unix_ms(5)
    LLM::AI::Transcript.current_system_prompt(messages).should eq "You are helpful.\n\nExtra rule.\n\n<skills>b</skills>"
  end

  it "returns no system message for transcripts without one" do
    messages = [LLM::AI::UserMessage.new("hi", Time.utc)] of LLM::AI::Message
    LLM::AI::Transcript.current_system_message(messages).should be_nil
    LLM::AI::Transcript.current_system_prompt(messages).should eq ""
  end

  it "diffs tool states, treating a changed definition as a removal and an addition" do
    changes = LLM::AI::Transcript.tool_state_changes([tool("a"), tool("b"), tool("c")], [tool("a"), tool("b", "changed"), tool("d")])
    changes.tools_added.map(&.name).should eq ["b", "d"]
    changes.tools_removed.map(&.name).should eq ["b", "c"]
    unchanged = LLM::AI::Transcript.tool_state_changes([tool("a")], [tool("a")])
    unchanged.tools_added.should be_empty
    unchanged.tools_removed.should be_empty
  end

  it "maps compat flags to tool support" do
    LLM::AI::Transcript.tool_support(model(LLM::AI::Compat.new)).should eq LLM::AI::ToolSupport::None
    LLM::AI::Transcript.tool_support(model(LLM::AI::Compat.new(supports_mid_convo_tool_changes: true))).should eq LLM::AI::ToolSupport::None
    LLM::AI::Transcript.tool_support(model(LLM::AI::Compat.new(supports_mid_convo_system_messages: true, supports_mid_convo_tool_additions: true))).should eq LLM::AI::ToolSupport::Additions
    LLM::AI::Transcript.tool_support(model(LLM::AI::Compat.new(supports_mid_convo_system_messages: true, supports_mid_convo_tool_changes: true))).should eq LLM::AI::ToolSupport::Changes
  end

  it "folds tool state for each support level" do
    systems = [
      system("lead", added: [tool("a")]),
      system("", added: [tool("b")]),
      system("", removed: ["a"]),
      system("", added: [tool("c")]),
    ]
    none = LLM::AI::Transcript.resolve_tools(systems, 1, LLM::AI::ToolSupport::None)
    none.folded_system_messages.should eq 4
    none.request_tools.map(&.name).should eq ["b", "c"]
    additions = LLM::AI::Transcript.resolve_tools(systems, 1, LLM::AI::ToolSupport::Additions)
    additions.folded_system_messages.should eq 3
    additions.request_tools.map(&.name).should eq ["b"]
    changes = LLM::AI::Transcript.resolve_tools(systems, 1, LLM::AI::ToolSupport::Changes)
    changes.folded_system_messages.should eq 1
    changes.request_tools.map(&.name).should eq ["a"]
  end

  it "treats a redeclaration as non-additive even after a removal" do
    systems = [system("", added: [tool("a")]), system("", removed: ["a"]), system("", added: [tool("a")]), system("", added: [tool("b")])]
    resolved = LLM::AI::Transcript.resolve_tools(systems, 1, LLM::AI::ToolSupport::Additions)
    resolved.folded_system_messages.should eq 3
    resolved.request_tools.map(&.name).should eq ["a"]
  end

  it "renders leading and update text" do
    message = system("Base.", {"rules" => "Be kind.", "old" => nil} of String => String?)
    LLM::AI::Transcript.system_text(message).should eq "Base.\n\nBe kind."
    LLM::AI::Transcript.system_update_text(message).should eq "Base.\n\nUpdated system prompt section \"rules\":\n\nBe kind.\n\nRemoved system prompt section \"old\"."
  end
end
