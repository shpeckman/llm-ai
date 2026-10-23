# spec/openai_responses_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def openai_responses_model(base_url : String = "http://127.0.0.1") : LLM::AI::Model
  LLM::AI::Model.new("deepseek-flash", "DeepSeek V4.1 Flash", "deepseek-responses", base_url, LLM::AI::ApiKind::OpenaiResponses,
    [LLM::AI::InputKind::Text], 1_000_000, 393_216, true,
    LLM::AI::ModelCost.new(0.15, 0.6, 0.003, 0.15),
    {"minimal" => "low", "low" => "low", "medium" => "high", "high" => "high", "xhigh" => "high", "max" => "max"} of String => String?,
    false, nil, LLM::AI::Compat.new)
end

private def openai_responses_auth : LLM::AI::Auth::AuthResult
  LLM::AI::Auth::AuthResult.new(LLM::AI::Auth::ModelAuth.new("sk-deepseek"), "ambient env")
end

private def openai_responses_context : LLM::AI::Context
  LLM::AI::Context.new([LLM::AI::UserMessage.new("hi", Time.utc)] of LLM::AI::Message)
end

private def openai_responses_sse(events : Array(String)) : String
  events.map { |event| "#{event}\n\n" }.join
end

private def openai_responses_event(name : String, data : String) : String
  "event: #{name}\ndata: #{data}"
end

private def openai_responses_text_events(output_index : Int32, deltas : Array(String)) : Array(String)
  events = [openai_responses_event("response.output_item.added", {"type" => "response.output_item.added", "output_index" => output_index, "item" => {"type" => "message", "id" => "msg_1"}}.to_json)]
  deltas.each_with_index do |delta, i|
    events << openai_responses_event("response.output_text.delta", {"type" => "response.output_text.delta", "output_index" => output_index, "content_index" => 0, "delta" => delta, "sequence_number" => i + 1}.to_json)
  end
  events << openai_responses_event("response.output_item.done", {"type" => "response.output_item.done", "output_index" => output_index, "item" => {"type" => "message", "id" => "msg_1"}}.to_json)
  events
end

describe LLM::AI::Api::OpenAIResponses do
  it "streams text and completes with usage" do
    completed = openai_responses_event("response.completed", {
      "type"     => "response.completed",
      "response" => {
        "id"     => "resp_1",
        "model"  => "deepseek-flash",
        "status" => "completed",
        "usage"  => {
          "input_tokens"          => 10,
          "input_tokens_details"  => {"cached_tokens" => 2},
          "output_tokens"         => 3,
          "output_tokens_details" => {"reasoning_tokens" => 1},
          "total_tokens"          => 13,
        },
      },
    }.to_json)
    body = openai_responses_sse([
      openai_responses_event("response.created", {"type" => "response.created", "response" => {"id" => "resp_1", "status" => "in_progress"}}.to_json),
      *openai_responses_text_events(0, ["hello", " world"]),
      completed,
    ])
    api = MockApi.new.serve(body).start
    begin
      model = openai_responses_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAIResponses.stream(model, openai_responses_context, LLM::AI::StreamOptions.new, openai_responses_auth, nil)
      events = [] of LLM::AI::StreamEvent
      stream.each { |event| events << event }
      events.first.should be_a(LLM::AI::StreamEvent::Start)
      events.select(LLM::AI::StreamEvent::TextDelta).map(&.text).join.should eq "hello world"
      events.last.should be_a(LLM::AI::StreamEvent::Done)
      result = stream.result
      result.stop_reason.should eq LLM::AI::StopReason::Stop
      result.response_id.should eq "resp_1"
      result.api.should eq "openai_responses"
      usage = result.usage.not_nil!
      usage.input.should eq 8
      usage.output.should eq 3
      usage.cache_read.should eq 2
      usage.reasoning.should eq 1
      api.requests[0][1].should eq "/responses"
      api.last_headers.not_nil!["Authorization"].should eq "Bearer sk-deepseek"
    ensure
      api.close
    end
  end

  it "streams reasoning_text and tool calls" do
    events = [
      openai_responses_event("response.output_item.added", {"type" => "response.output_item.added", "output_index" => 0, "item" => {"type" => "reasoning", "id" => "rs_1"}}.to_json),
      openai_responses_event("response.reasoning_text.delta", {"type" => "response.reasoning_text.delta", "output_index" => 0, "content_index" => 0, "delta" => "thinking"}.to_json),
      openai_responses_event("response.output_item.done", {"type" => "response.output_item.done", "output_index" => 0, "item" => {"type" => "reasoning", "id" => "rs_1"}}.to_json),
      openai_responses_event("response.output_item.added", {"type" => "response.output_item.added", "output_index" => 1, "item" => {"type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "lookup"}}.to_json),
      openai_responses_event("response.function_call_arguments.delta", {"type" => "response.function_call_arguments.delta", "output_index" => 1, "delta" => "{\"q\":"}.to_json),
      openai_responses_event("response.function_call_arguments.delta", {"type" => "response.function_call_arguments.delta", "output_index" => 1, "delta" => "\"x\"}"}.to_json),
      openai_responses_event("response.output_item.done", {"type" => "response.output_item.done", "output_index" => 1, "item" => {"type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "lookup", "arguments" => "{\"q\":\"x\"}"}}.to_json),
      openai_responses_event("response.completed", {"type" => "response.completed", "response" => {"id" => "resp_2", "status" => "completed", "usage" => {"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}}}.to_json),
    ]
    api = MockApi.new.serve(openai_responses_sse(events)).start
    begin
      model = openai_responses_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAIResponses.stream(model, openai_responses_context, LLM::AI::StreamOptions.new, openai_responses_auth, nil)
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

  it "dispatches on the data type when the SSE event name is missing" do
    events = [
      %<data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_1"}}>,
      %<data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"hi"}>,
      %<data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_1"}}>,
      %<data: {"type":"response.completed","response":{"id":"resp_5","status":"completed","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}>,
    ]
    api = MockApi.new.serve(openai_responses_sse(events)).start
    begin
      model = openai_responses_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAIResponses.stream(model, openai_responses_context, LLM::AI::StreamOptions.new, openai_responses_auth, nil)
      result = stream.result
      result.stop_reason.should eq LLM::AI::StopReason::Stop
      result.content.select(LLM::AI::TextContent).map(&.text).join.should eq "hi"
    ensure
      api.close
    end
  end

  it "ignores web_search_call items" do
    events = [
      openai_responses_event("response.output_item.added", {"type" => "response.output_item.added", "output_index" => 0, "item" => {"type" => "web_search_call", "id" => "ws_1"}}.to_json),
      openai_responses_event("response.web_search_call.completed", {"type" => "response.web_search_call.completed", "output_index" => 0, "item_id" => "ws_1"}.to_json),
      *openai_responses_text_events(1, ["done"]),
      openai_responses_event("response.completed", {"type" => "response.completed", "response" => {"id" => "resp_6", "status" => "completed", "usage" => {"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}}}.to_json),
    ]
    api = MockApi.new.serve(openai_responses_sse(events)).start
    begin
      model = openai_responses_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAIResponses.stream(model, openai_responses_context, LLM::AI::StreamOptions.new, openai_responses_auth, nil)
      result = stream.result
      result.stop_reason.should eq LLM::AI::StopReason::Stop
      result.content.select(LLM::AI::TextContent).map(&.text).join.should eq "done"
    ensure
      api.close
    end
  end

  it "maps incomplete max_output_tokens to length" do
    events = openai_responses_text_events(0, ["partial"])
    events << openai_responses_event("response.incomplete", {"type" => "response.incomplete", "response" => {"id" => "resp_3", "status" => "incomplete", "incomplete_details" => {"reason" => "max_output_tokens"}, "usage" => {"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}}}.to_json)
    api = MockApi.new.serve(openai_responses_sse(events)).start
    begin
      model = openai_responses_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAIResponses.stream(model, openai_responses_context, LLM::AI::StreamOptions.new, openai_responses_auth, nil)
      result = stream.result
      result.stop_reason.should eq LLM::AI::StopReason::Length
    ensure
      api.close
    end
  end

  it "maps failed responses to stream errors" do
    failed = openai_responses_sse([
      openai_responses_event("response.failed", {"type" => "response.failed", "response" => {"id" => "resp_4", "status" => "failed", "error" => {"code" => "server_error", "message" => "boom"}}}.to_json),
    ])
    api = MockApi.new.serve(failed).start
    begin
      model = openai_responses_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAIResponses.stream(model, openai_responses_context, LLM::AI::StreamOptions.new, openai_responses_auth, nil)
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
      "deepseek-responses", "deepseek-flash", Time.utc)
    result_msg = LLM::AI::ToolResultMessage.new("call_1", "lookup", [LLM::AI::TextContent.new("found")] of LLM::AI::ContentBlock, Time.utc)
    context = LLM::AI::Context.new(
      [LLM::AI::UserMessage.new("hi", Time.utc), assistant, result_msg] of LLM::AI::Message,
      system_prompt: "be nice", tools: [tool])
    options = LLM::AI::StreamOptions.new(
      thinking_level: "medium",
      max_tokens: 1024,
      response_format: JSON.parse(%({"type":"json_object"})),
      tool_choice: "auto",
      user_id: "user-42",
      prompt_cache_key: "session-1")
    payload = JSON.parse(LLM::AI::Api::OpenAIResponses.build_payload(openai_responses_model, context, options))
    payload["model"].should eq "deepseek-flash"
    payload["instructions"].should eq "be nice"
    payload["stream"].should be_true
    payload["max_output_tokens"].should eq 17_408
    payload["reasoning"]["effort"].should eq "high"
    payload["text"]["format"]["type"].should eq "json_object"
    payload["tool_choice"].should eq "auto"
    payload["user"].should eq "user-42"
    payload.as_h.has_key?("prompt_cache_key").should be_false
    payload.as_h.has_key?("store").should be_false
    payload["tools"][0]["type"].should eq "function"
    payload["tools"][0]["name"].should eq "lookup"
    input = payload["input"].as_a
    input[0].should eq JSON.parse(%({"role":"user","content":"hi"}))
    input[1]["type"].should eq "reasoning"
    input[2]["role"].should eq "assistant"
    input[2]["content"][0].should eq JSON.parse(%({"type":"output_text","text":"answer"}))
    input[3]["type"].should eq "function_call"
    input[3]["call_id"].should eq "call_1"
    input[3].as_h.has_key?("namespace").should be_false
    input[4].should eq JSON.parse(%({"type":"function_call_output","call_id":"call_1","output":"found"}))
  end

  it "defaults reasoning effort to high and omits reasoning when thinking is off" do
    enabled = JSON.parse(LLM::AI::Api::OpenAIResponses.build_payload(
      openai_responses_model, openai_responses_context, LLM::AI::StreamOptions.new(thinking_enabled: true)))
    enabled["reasoning"]["effort"].should eq "high"
    disabled = JSON.parse(LLM::AI::Api::OpenAIResponses.build_payload(
      openai_responses_model, openai_responses_context, LLM::AI::StreamOptions.new))
    disabled.as_h.has_key?("reasoning").should be_false
  end
end
