# spec/validation_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def tool(schema : String) : LLM::AI::Tool
  LLM::AI::Tool.new("echo", "Echo", JSON.parse(schema))
end

private def call(arguments : String, error : String? = nil) : LLM::AI::ToolCall
  LLM::AI::ToolCall.new("call-1", "echo", JSON.parse(arguments), arguments_error: error)
end

describe LLM::AI::Validation do
  it "returns valid arguments as a copy" do
    tool_call = call(%({"value":"hi"}))
    args = LLM::AI::Validation.validate_tool_arguments(tool(%({"type":"object","properties":{"value":{"type":"string"}},"required":["value"]})), tool_call)
    args.should eq JSON.parse(%({"value":"hi"}))
    args.as_h["value"] = JSON::Any.new("changed")
    tool_call.arguments["value"].should eq "hi"
  end

  it "coerces primitives to the schema types" do
    schema = tool(%({"type":"object","properties":{"count":{"type":"integer"},"ratio":{"type":"number"},"flag":{"type":"boolean"},"label":{"type":"string"},"items":{"type":"array","items":{"type":"number"}}}}))
    args = LLM::AI::Validation.validate_tool_arguments(schema, call(%({"count":"3","ratio":"1.5","flag":"true","label":7,"items":["1","2.5"]})))
    args.should eq JSON.parse(%({"count":3,"ratio":1.5,"flag":true,"label":"7","items":[1,2.5]}))
  end

  it "coerces union members to the first schema they satisfy" do
    schema = tool(%({"type":"object","properties":{"value":{"anyOf":[{"type":"number"},{"type":"boolean"}]}}}))
    LLM::AI::Validation.validate_tool_arguments(schema, call(%({"value":"false"})))["value"].as_bool.should be_false
    LLM::AI::Validation.validate_tool_arguments(schema, call(%({"value":"4"})))["value"].should eq 4
  end

  it "drops null optional properties that do not accept null" do
    schema = tool(%({"type":"object","properties":{"value":{"type":"string"},"note":{"type":"string"},"maybe":{"type":["string","null"]}},"required":["value"]}))
    args = LLM::AI::Validation.validate_tool_arguments(schema, call(%({"value":"x","note":null,"maybe":null})))
    args.should eq JSON.parse(%({"value":"x","maybe":null}))
  end

  it "formats validation failures with paths and the received arguments" do
    schema = tool(%({"type":"object","properties":{"value":{"type":"string"},"nested":{"type":"object","properties":{"n":{"type":"number"}},"required":["n"]}},"required":["value"]}))
    error = expect_raises(LLM::AI::ToolValidationError) do
      LLM::AI::Validation.validate_tool_arguments(schema, call(%({"nested":{}})))
    end
    message = error.message.not_nil!
    message.should start_with "Validation failed for tool \"echo\":\n"
    message.should contain "  - value: must have required properties value"
    message.should contain "  - nested.n: must have required properties n"
    message.should end_with "Received arguments:\n{\n  \"nested\": {}\n}"
  end

  it "reports argument parse errors before validating" do
    expect_raises(LLM::AI::ToolValidationError, "Invalid arguments for tool \"echo\": bad json") do
      LLM::AI::Validation.validate_tool_arguments(tool(%({"type":"object"})), call("{}", "bad json"))
    end
  end

  it "finds the tool for a call" do
    tools = [tool(%({"type":"object"}))]
    LLM::AI::Validation.validate_tool_call(tools, call(%({"a":1}))).should eq JSON.parse(%({"a":1}))
    missing = LLM::AI::ToolCall.new("c", "missing", JSON.parse("{}"))
    expect_raises(LLM::AI::ToolValidationError, "Tool \"missing\" not found") do
      LLM::AI::Validation.validate_tool_call(tools, missing)
    end
  end
end
