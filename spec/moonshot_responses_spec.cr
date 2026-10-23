# spec/moonshot_responses_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def responses_model(base_url : String = "http://127.0.0.1") : LLM::AI::Model
  LLM::AI::Model.new("kimi-k3", "Kimi K3", "moonshot-responses", base_url, LLM::AI::ApiKind::MoonshotResponses,
    [LLM::AI::InputKind::Text], 1_048_576, 131_072, true,
    LLM::AI::ModelCost.new(3.0, 15.0, 0.3, 3.0, 6.0),
    {"low" => "low", "high" => "high", "max" => "max"} of String => String?, false, nil, LLM::AI::Compat.new)
end

private def responses_auth : LLM::AI::Auth::AuthResult
  LLM::AI::Auth::AuthResult.new(LLM::AI::Auth::ModelAuth.new("sk-moonshot"), "ambient env")
end

private def responses_context : LLM::AI::Context
  LLM::AI::Context.new([LLM::AI::UserMessage.new("hi", Time.utc)] of LLM::AI::Message)
end

private def responses_sse(events : Array(String)) : String
  events.map { |event| "#{event}\n\n" }.join
end

private def sse_event(name : String, data : String) : String
  "event: #{name}\ndata: #{data}"
end

private def text_item_events(output_index : Int32, deltas : Array(String)) : Array(String)
  events = [sse_event("response.output_item.added", {"type" => "response.output_item.added", "output_index" => output_index, "item" => {"type" => "message", "id" => "msg_1"}}.to_json)]
  deltas.each_with_index do |delta, i|
    events << sse_event("response.output_text.delta", {"type" => "response.output_text.delta", "output_index" => output_index, "content_index" => 0, "delta" => delta, "sequence_number" => i + 1}.to_json)
  end
  events << sse_event("response.output_item.done", {"type" => "response.output_item.done", "output_index" => output_index, "item" => {"type" => "message", "id" => "msg_1"}}.to_json)
  events
end

describe LLM::AI::Api::MoonshotResponses do
  it "streams text and completes with usage" do
    completed = sse_event("response.completed", {
      "type"     => "response.completed",
      "response" => {
        "id"     => "resp_1",
        "model"  => "kimi-k3",
        "status" => "completed",
        "usage"  => {
          "input_tokens"          => 10,
          "input_tokens_details"  => {"cached_tokens" => 2, "cache_write_tokens" => 0},
          "output_tokens"         => 3,
          "output_tokens_details" => {"reasoning_tokens" => 1},
          "total_tokens"          => 13,
        },
      },
    }.to_json)
    body = responses_sse([
      sse_event("response.created", {"type" => "response.created", "response" => {"id" => "resp_1", "status" => "in_progress"}}.to_json),
      *text_item_events(0, ["hello", " world"]),
      completed,
    ])
    api = MockApi.new.serve(body).start
    begin
      model = responses_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::Responses.stream(model, responses_context, LLM::AI::StreamOptions.new, responses_auth, nil)
      events = [] of LLM::AI::StreamEvent
      stream.each { |event| events << event }
      events.first.should be_a(LLM::AI::StreamEvent::Start)
      events.select(LLM::AI::StreamEvent::TextDelta).map(&.text).join.should eq "hello world"
      events.last.should be_a(LLM::AI::StreamEvent::Done)
      result = stream.result
      result.stop_reason.should eq LLM::AI::StopReason::Stop
      result.response_id.should eq "resp_1"
      result.api.should eq "moonshot_responses"
      usage = result.usage.not_nil!
      usage.input.should eq 8
      usage.output.should eq 3
      usage.cache_read.should eq 2
      usage.reasoning.should eq 1
      api.requests[0][1].should eq "/responses"
      api.last_headers.not_nil!["Authorization"].should eq "Bearer sk-moonshot"
    ensure
      api.close
    end
  end

  it "streams reasoning and tool calls" do
    events = [
      sse_event("response.output_item.added", {"type" => "response.output_item.added", "output_index" => 0, "item" => {"type" => "reasoning", "id" => "rs_1"}}.to_json),
      sse_event("response.reasoning_summary_text.delta", {"type" => "response.reasoning_summary_text.delta", "output_index" => 0, "summary_index" => 0, "delta" => "thinking"}.to_json),
      sse_event("response.output_item.done", {"type" => "response.output_item.done", "output_index" => 0, "item" => {"type" => "reasoning", "id" => "rs_1"}}.to_json),
      sse_event("response.output_item.added", {"type" => "response.output_item.added", "output_index" => 1, "item" => {"type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "lookup"}}.to_json),
      sse_event("response.function_call_arguments.delta", {"type" => "response.function_call_arguments.delta", "output_index" => 1, "delta" => "{\"q\":"}.to_json),
      sse_event("response.function_call_arguments.delta", {"type" => "response.function_call_arguments.delta", "output_index" => 1, "delta" => "\"x\"}"}.to_json),
      sse_event("response.output_item.done", {"type" => "response.output_item.done", "output_index" => 1, "item" => {"type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "lookup", "arguments" => "{\"q\":\"x\"}"}}.to_json),
      sse_event("response.completed", {"type" => "response.completed", "response" => {"id" => "resp_2", "status" => "completed", "usage" => {"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}}}.to_json),
    ]
    api = MockApi.new.serve(responses_sse(events)).start
    begin
      model = responses_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::Responses.stream(model, responses_context, LLM::AI::StreamOptions.new, responses_auth, nil)
      result = stream.result
      result.stop_reason.should eq LLM::AI::StopReason::ToolUse
      thinking = result.content.select(LLM::AI::ThinkingContent)
      thinking.map(&.thinking).join.should eq "thinking"
      tool = result.content.select(LLM::AI::ToolCall).first
      tool.id.should eq "call_1"
      tool.name.should eq "lookup"
      tool.arguments.should eq JSON.parse(%({"q":"x"}))
      tool.arguments_error.should be_nil
    ensure
      api.close
    end
  end

  it "maps incomplete max_output_tokens to length" do
    events = text_item_events(0, ["partial"])
    events << sse_event("response.incomplete", {"type" => "response.incomplete", "response" => {"id" => "resp_3", "status" => "incomplete", "incomplete_details" => {"reason" => "max_output_tokens"}, "usage" => {"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}}}.to_json)
    api = MockApi.new.serve(responses_sse(events)).start
    begin
      model = responses_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::Responses.stream(model, responses_context, LLM::AI::StreamOptions.new, responses_auth, nil)
      result = stream.result
      result.stop_reason.should eq LLM::AI::StopReason::Length
    ensure
      api.close
    end
  end

  it "maps failed responses and error events to stream errors" do
    failed = responses_sse([
      sse_event("response.failed", {"type" => "response.failed", "response" => {"id" => "resp_4", "status" => "failed", "error" => {"code" => "server_error", "message" => "boom"}}}.to_json),
    ])
    api = MockApi.new.serve(failed).start
    begin
      model = responses_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::Responses.stream(model, responses_context, LLM::AI::StreamOptions.new, responses_auth, nil)
      expect_raises(LLM::AI::ModelsError, /boom/) { stream.result }
    ensure
      api.close
    end
  end

  it "builds the payload from a context" do
    tool = LLM::AI::Tool.new("lookup", "look up", JSON.parse(%({"type":"object"})))
    assistant = LLM::AI::AssistantMessage.new(
      [
        LLM::AI::ThinkingContent.new("hmm"),
        LLM::AI::TextContent.new("answer"),
        LLM::AI::ToolCall.new("call_1", "lookup", JSON.parse(%({"q":"x"}))),
      ] of LLM::AI::ContentBlock,
      "moonshot-responses", "kimi-k3", Time.utc)
    result_msg = LLM::AI::ToolResultMessage.new("call_1", "lookup", [LLM::AI::TextContent.new("found")] of LLM::AI::ContentBlock, Time.utc)
    context = LLM::AI::Context.new(
      [LLM::AI::UserMessage.new("hi", Time.utc), assistant, result_msg] of LLM::AI::Message,
      system_prompt: "be nice", tools: [tool])
    options = LLM::AI::StreamOptions.new(
      thinking_level: "high",
      max_tokens: 1024,
      response_format: JSON.parse(%({"type":"json_schema","name":"out","schema":{"type":"object"}})),
      prompt_cache_key: "session-1",
      safety_identifier: "user-42")
    payload = JSON.parse(LLM::AI::Api::Responses.build_payload(responses_model, context, options))
    payload["model"].should eq "kimi-k3"
    payload["instructions"].should eq "be nice"
    payload["stream"].should be_true
    payload["max_output_tokens"].should eq 17_408
    payload["reasoning"]["effort"].should eq "high"
    payload["text"]["format"]["name"].should eq "out"
    payload["prompt_cache_key"].should eq "session-1"
    payload["safety_identifier"].should eq "user-42"
    payload["tool_choice"].should eq "auto"
    payload["tools"][0]["type"].should eq "function"
    payload["tools"][0]["name"].should eq "lookup"
    input = payload["input"].as_a
    input[0].should eq JSON.parse(%({"role":"user","content":"hi"}))
    input[1]["type"].should eq "reasoning"
    input[2]["role"].should eq "assistant"
    input[2]["content"][0].should eq JSON.parse(%({"type":"output_text","text":"answer"}))
    input[3]["type"].should eq "function_call"
    input[3]["call_id"].should eq "call_1"
    input[3]["arguments"].should eq %({"q":"x"})
    input[4].should eq JSON.parse(%({"type":"function_call_output","call_id":"call_1","output":"found"}))
  end
end
