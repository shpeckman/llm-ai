# spec/types_spec.cr
require "./spec_helper"
require "../src/llm-ai"

describe LLM::AI do
  ts = Time.unix_ms(1_750_000_000_000)

  describe "types" do
    it "round-trips an assistant message with tool call through JSON" do
      usage = LLM::AI::Usage.new(
        input: 100,
        output: 50,
        cache_read: 20,
        cache_write: 10,
        total_tokens: 150,
        cost: LLM::AI::UsageCost.new(
          input: 0.0001,
          output: 0.0002,
          cache_read: 0.00005,
          cache_write: 0.0001,
          total: 0.0003
        )
      )
      msg = LLM::AI::AssistantMessage.new(
        content: [
          LLM::AI::TextContent.new("Paris weather:"),
          LLM::AI::ThinkingContent.new("Let me check the forecast", redacted: false),
          LLM::AI::ToolCall.new("call_1", "get_weather", JSON.parse(%({"city":"paris"}))),
        ],
        provider: "deepseek",
        model: "deepseek-chat",
        usage: usage,
        stop_reason: LLM::AI::StopReason::ToolUse,
        timestamp: ts,
      )
      parsed = LLM::AI::AssistantMessage.from_json(msg.to_json)
      parsed.should eq msg
      parsed.stop_reason.should eq LLM::AI::StopReason::ToolUse
      parsed.usage.not_nil!.cost.total.should eq 0.0003
    end

    it "round-trips reasoning_details on an assistant message through JSON" do
      details = JSON.parse(%([{"type":"reasoning.text","text":"hi","signature":"sig"},{"type":"reasoning.encrypted","data":"abc"}]))
      msg = LLM::AI::AssistantMessage.new(
        content: [LLM::AI::TextContent.new("answer")] of LLM::AI::ContentBlock,
        provider: "deepseek",
        model: "deepseek-chat",
        timestamp: ts,
        reasoning_details: details,
      )
      parsed = LLM::AI::AssistantMessage.from_json(msg.to_json)
      parsed.should eq msg
      parsed.reasoning_details.should eq details
      parsed.reasoning_details.not_nil!.as_a.size.should eq 2
    end

    it "round-trips each message role" do
      system = LLM::AI::SystemMessage.new(
        content: "You are a helpful assistant.",
        sections: {"rules" => "be concise", "tone" => nil},
        tools_added: [LLM::AI::Tool.new("search", "Search the web", JSON.parse(%({"type":"object","properties":{}})))],
        tools_removed: [LLM::AI::ToolReference.new("browse")],
        timestamp: ts,
      )
      system.to_json.should contain %("role":"system")
      LLM::AI::Message.from_json(system.to_json).should eq system

      user = LLM::AI::UserMessage.new(content: "hi", timestamp: ts)
      user.to_json.should contain %("role":"user")
      LLM::AI::Message.from_json(user.to_json).should eq user

      user_img_content : Array(LLM::AI::ContentBlock) = [
        LLM::AI::TextContent.new("what is this"),
        LLM::AI::ImageContent.new("aGVsbG8=", "image/png"),
      ]
      user_img = LLM::AI::UserMessage.new(content: user_img_content, timestamp: ts)
      LLM::AI::Message.from_json(user_img.to_json).should eq user_img

      tool_result = LLM::AI::ToolResultMessage.new(
        tool_call_id: "call_1",
        tool_name: "get_weather",
        content: [LLM::AI::TextContent.new("22C, clear")] of LLM::AI::ContentBlock,
        is_error: false,
        timestamp: ts,
        duration_ms: 42,
      )
      tool_result.to_json.should contain %("role":"toolResult")
      LLM::AI::Message.from_json(tool_result.to_json).should eq tool_result
    end

    it "serializes stop reasons as lowercase strings" do
      LLM::AI::StopReason::ToolUse.to_json.should eq %("tool_use")
      LLM::AI::StopReason::Pending.to_json.should eq %("pending")
      LLM::AI::StopReason::Length.to_json.should eq %("length")
    end

    it "round-trips every stream event kind" do
      partial = LLM::AI::AssistantMessage.new(
        content: [LLM::AI::TextContent.new("so far")] of LLM::AI::ContentBlock,
        provider: "deepseek",
        model: "deepseek-chat",
        timestamp: ts,
      )
      events = {
        LLM::AI::StreamEvent::Start.new(partial)                           => "start",
        LLM::AI::StreamEvent::TextStart.new(0, partial)                    => "text_start",
        LLM::AI::StreamEvent::TextDelta.new(0, "hel", partial)             => "text_delta",
        LLM::AI::StreamEvent::TextEnd.new(0, partial)                      => "text_end",
        LLM::AI::StreamEvent::ThinkingStart.new(0, partial)                => "thinking_start",
        LLM::AI::StreamEvent::ThinkingDelta.new(0, "th", partial)          => "thinking_delta",
        LLM::AI::StreamEvent::ThinkingEnd.new(0, partial)                  => "thinking_end",
        LLM::AI::StreamEvent::ToolCallStart.new(0, partial)                => "toolcall_start",
        LLM::AI::StreamEvent::ToolCallDelta.new(0, partial)                => "toolcall_delta",
        LLM::AI::StreamEvent::ToolCallEnd.new(0, partial)                  => "toolcall_end",
        LLM::AI::StreamEvent::Done.new(LLM::AI::StopReason::Stop, partial) => "done",
        LLM::AI::StreamEvent::Error.new(:error, partial)                   => "error",
      }
      events.each do |event, type_name|
        json = event.to_json
        json.should contain %("type":"#{type_name}")
        LLM::AI::StreamEvent.from_json(json).should eq event
      end
    end

    it "defaults compat flags to TS defaults" do
      compat = LLM::AI::Compat.new
      compat.max_tokens_field.should eq :max_completion_tokens
      compat.supports_finish_reason.should be_true
      compat.supports_eager_tool_input_streaming.should be_true
      compat.supports_temperature.should be_true
      compat.supports_usage_in_streaming.should be_true
      compat.supports_store.should be_true
    end
  end
end
