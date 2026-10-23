# spec/openai_completions_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def deepseek_model(base_url : String = "http://127.0.0.1") : LLM::AI::Model
  compat = LLM::AI::Compat.new(
    max_tokens_field: :max_tokens,
    thinking_format: :deepseek,
    requires_reasoning_content_on_assistant_messages: true,
    supports_store: false,
    supports_response_format: true,
  )
  LLM::AI::Model.new("deepseek-chat", "deepseek-chat", "deepseek", base_url, LLM::AI::ApiKind::OpenaiCompletions,
    [LLM::AI::InputKind::Text], 128_000, 8192, true,
    LLM::AI::ModelCost.new(0.27, 1.1, 0.07, 0.27, nil),
    {"minimal" => "low", "low" => "low", "medium" => "high", "high" => "high", "xhigh" => "high", "max" => "max", "off" => nil}, false, nil, compat)
end

private def kimi_model(base_url : String = "http://127.0.0.1") : LLM::AI::Model
  compat = LLM::AI::Compat.new(max_tokens_field: :max_completion_tokens)
  LLM::AI::Model.new("kimi-k3", "Kimi K3", "kimi-coding", base_url, LLM::AI::ApiKind::OpenaiCompletions,
    [LLM::AI::InputKind::Text], 256_000, 8192, true,
    LLM::AI::ModelCost.new(1.2, 4.0, 0.15, 1.2, nil),
    {"high" => "high", "off" => nil}, false, nil, compat)
end

private def vision_model : LLM::AI::Model
  compat = LLM::AI::Compat.new(
    max_tokens_field: :max_tokens,
    requires_tool_result_name: true,
    requires_assistant_after_tool_result: true,
  )
  LLM::AI::Model.new("vision", "vision", "p", "http://127.0.0.1", LLM::AI::ApiKind::OpenaiCompletions,
    [LLM::AI::InputKind::Text, LLM::AI::InputKind::Image], 128_000, 8192, false,
    LLM::AI::ModelCost.new(0.27, 1.1, 0.07, 0.27, nil),
    compat: compat)
end

private def kimi_model_with_tool_updates : LLM::AI::Model
  compat = LLM::AI::Compat.new(
    max_tokens_field: :max_completion_tokens,
    supports_mid_convo_system_messages: true,
    supports_mid_convo_tool_additions: true,
  )
  LLM::AI::Model.new("kimi-k3", "Kimi K3", "kimi-coding", "http://127.0.0.1", LLM::AI::ApiKind::OpenaiCompletions,
    [LLM::AI::InputKind::Text], 256_000, 8192, true,
    LLM::AI::ModelCost.new(1.2, 4.0, 0.15, 1.2, nil),
    {"high" => "high", "off" => nil}, false, nil, compat)
end

private def auth_result : LLM::AI::Auth::AuthResult
  LLM::AI::Auth::AuthResult.new(LLM::AI::Auth::ModelAuth.new("test-key"), "ambient env")
end

private def user_context(text : String = "hi") : LLM::AI::Context
  LLM::AI::Context.new([LLM::AI::UserMessage.new([LLM::AI::TextContent.new(text)] of LLM::AI::ContentBlock, Time.utc)] of LLM::AI::Message)
end

private def sse_body(chunks : Array(String)) : String
  chunks.map { |chunk| "data: #{chunk}\n\n" }.join
end

private def content_chunk(content : String) : String
  {"choices" => [{"index" => 0, "delta" => {"content" => content}, "finish_reason" => JSON::Any.new(nil)}]}.to_json
end

private def final_chunk(finish : String, usage : Hash(String, JSON::Any)) : String
  {"choices" => [{"index" => 0, "delta" => {} of String => JSON::Any, "finish_reason" => finish}], "usage" => usage}.to_json
end

private def usage_json(prompt : Int32, completion : Int32, cached : Int32 = 0) : Hash(String, JSON::Any)
  {
    "prompt_tokens"             => JSON::Any.new(prompt),
    "completion_tokens"         => JSON::Any.new(completion),
    "prompt_tokens_details"     => JSON::Any.new({"cached_tokens" => JSON::Any.new(cached)}),
    "completion_tokens_details" => JSON::Any.new({"reasoning_tokens" => JSON::Any.new(0)}),
  }
end

describe LLM::AI::Api::OpenAICompletions do
  it "streams plain text and finishes with usage" do
    body = sse_body([
      content_chunk("hello"),
      content_chunk(" "),
      content_chunk("world"),
      final_chunk("stop", usage_json(10, 3, cached: 2)),
      "[DONE]",
    ])
    api = MockApi.new.serve(body).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, nil)
      events = [] of LLM::AI::StreamEvent
      stream.each { |event| events << event }
      events.first.should be_a(LLM::AI::StreamEvent::Start)
      events.select(LLM::AI::StreamEvent::TextDelta).map(&.text).join.should eq "hello world"
      events.last.should be_a(LLM::AI::StreamEvent::Done)
      result = stream.result
      result.usage.not_nil!.input.should eq 8
      result.usage.not_nil!.output.should eq 3
      result.usage.not_nil!.cache_read.should eq 2
      result.usage.not_nil!.total_tokens.should eq 13
      result.usage.not_nil!.cost.should eq LLM::AI::Pricing.calculate(model, result.usage.not_nil!)
    ensure
      api.close
    end
  end

  it "passes each parsed chunk to on_provider_event" do
    body = sse_body([content_chunk("hi"), final_chunk("stop", usage_json(1, 1)), "[DONE]"])
    api = MockApi.new.serve(body).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      seen = [] of JSON::Any
      hooks = LLM::AI::StreamHooks.new(on_provider_event: ->(data : JSON::Any, target : LLM::AI::Model) { seen << data; target.id.should eq "deepseek-chat"; nil })
      LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new(hooks: hooks), auth_result, nil).result
      seen.size.should eq 2
      seen[0]["choices"][0]["delta"]["content"].should eq "hi"
      seen[1]["choices"][0]["finish_reason"].should eq "stop"
    ensure
      api.close
    end
  end

  it "accumulates a tool call split across deltas" do
    first = {"choices" => [{"index" => 0, "delta" => {"tool_calls" => [
      {"index" => 0, "id" => "t1", "type" => "function", "function" => {"name" => "get_weather", "arguments" => "{\"city\":\"pari"}},
    ]}, "finish_reason" => JSON::Any.new(nil)}]}.to_json
    second = {"choices" => [{"index" => 0, "delta" => {"tool_calls" => [
      {"index" => 0, "function" => {"arguments" => "s\"}"}},
    ]}, "finish_reason" => JSON::Any.new(nil)}]}.to_json
    body = sse_body([first, second, final_chunk("tool_calls", usage_json(5, 0))])
    api = MockApi.new.serve(body).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, nil)
      events = [] of LLM::AI::StreamEvent
      stream.each { |event| events << event }
      events.any?(LLM::AI::StreamEvent::ToolCallStart).should be_true
      first_delta = events.select(LLM::AI::StreamEvent::ToolCallDelta).first
      tool = first_delta.partial.content.select(LLM::AI::ToolCall).first.not_nil!
      tool.arguments.should eq JSON.parse("{\"city\":\"pari\"}")
      result = stream.result
      result.stop_reason.should eq LLM::AI::StopReason::ToolUse
      result.content.select(LLM::AI::ToolCall).first.not_nil!.arguments.should eq JSON.parse("{\"city\":\"paris\"}")
    ensure
      api.close
    end
  end

  it "finalizes malformed tool arguments as {} with arguments_error" do
    chunk = {"choices" => [{"index" => 0, "delta" => {"tool_calls" => [
      {"index" => 0, "id" => "t2", "function" => {"name" => "bad", "arguments" => "not json"}},
    ]}, "finish_reason" => JSON::Any.new(nil)}]}.to_json
    body = sse_body([chunk, final_chunk("tool_calls", usage_json(5, 0))])
    api = MockApi.new.serve(body).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, nil)
      result = stream.result
      tool = result.content.select(LLM::AI::ToolCall).first.not_nil!
      tool.arguments.should eq JSON.parse("{}")
      tool.arguments_error.should_not be_nil
    ensure
      api.close
    end
  end

  it "emits thinking deltas before text for deepseek" do
    thinking = {"choices" => [{"index" => 0, "delta" => {"reasoning_content" => "hmm"}, "finish_reason" => JSON::Any.new(nil)}]}.to_json
    body = sse_body([thinking, content_chunk("ok"), final_chunk("stop", usage_json(5, 2))])
    api = MockApi.new.serve(body).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, nil)
      events = [] of LLM::AI::StreamEvent
      stream.each { |event| events << event }
      first_after_start = events[1]
      first_after_start.should be_a(LLM::AI::StreamEvent::ThinkingStart)
      events[2].should be_a(LLM::AI::StreamEvent::ThinkingDelta)
      events.any?(LLM::AI::StreamEvent::TextStart).should be_true
      result = stream.result
      result.content.select(LLM::AI::ThinkingContent).first.not_nil!.thinking.should eq "hmm"
      result.content.select(LLM::AI::TextContent).first.not_nil!.text.should eq "ok"
    ensure
      api.close
    end
  end

  it "builds deepseek thinking params" do
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(
      deepseek_model, user_context, LLM::AI::StreamOptions.new(thinking_level: "high")))
    payload["thinking"]["type"].should eq "enabled"
    payload["reasoning_effort"].should eq "high"
    payload.as_h.has_key?("max_tokens").should be_true
    payload.as_h.has_key?("max_completion_tokens").should be_false
  end

  it "emits context.system_prompt as a leading system message" do
    context = LLM::AI::Context.new(
      [LLM::AI::UserMessage.new("hi", Time.utc)] of LLM::AI::Message,
      system_prompt: "be nice")
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(deepseek_model, context, LLM::AI::StreamOptions.new))
    payload["messages"][0]["role"].should eq "system"
    payload["messages"][0]["content"].should eq "be nice"
    payload["messages"][1]["role"].should eq "user"
  end

  it "replays reasoning_content on assistant messages" do
    assistant = LLM::AI::AssistantMessage.new([LLM::AI::TextContent.new("hi")] of LLM::AI::ContentBlock, "deepseek", "deepseek-chat", Time.utc)
    context = LLM::AI::Context.new([assistant] of LLM::AI::Message)
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(deepseek_model, context, LLM::AI::StreamOptions.new))
    payload["messages"][0]["reasoning_content"].should eq ""
  end

  it "builds kimi params" do
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(
      kimi_model, user_context, LLM::AI::StreamOptions.new(thinking_level: "high")))
    payload.as_h.has_key?("max_completion_tokens").should be_true
    payload.as_h.has_key?("max_tokens").should be_false
    payload["store"].should be_false
    payload["stream_options"]["include_usage"].should be_true
    payload["reasoning_effort"].should eq "high"
    payload.as_h.has_key?("thinking").should be_false
  end

  it "turns kimi mid-conversation tool additions into a system tools message" do
    tool = LLM::AI::Tool.new("lookup", "look up things", JSON.parse("{\"type\":\"object\"}"))
    system = LLM::AI::SystemMessage.new("sys", Time.utc, nil, [tool], nil)
    user = LLM::AI::UserMessage.new("hi", Time.utc)
    context = LLM::AI::Context.new([user, system] of LLM::AI::Message)
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(kimi_model_with_tool_updates, context, LLM::AI::StreamOptions.new))
    payload["messages"][1]["role"].should eq "system"
    payload["messages"][1]["tools"][0]["name"].should eq "lookup"
  end

  it "suppresses kimi tool additions without support flags or at index zero" do
    tool = LLM::AI::Tool.new("lookup", "look up things", JSON.parse("{\"type\":\"object\"}"))
    system = LLM::AI::SystemMessage.new("sys", Time.utc, nil, [tool], nil)
    user = LLM::AI::UserMessage.new("hi", Time.utc)

    at_index_zero = LLM::AI::Context.new([system] of LLM::AI::Message)
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(kimi_model_with_tool_updates, at_index_zero, LLM::AI::StreamOptions.new))
    payload["messages"].as_a.none? { |msg| msg["tools"]? }.should be_true

    flags_off = LLM::AI::Context.new([user, system] of LLM::AI::Message)
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(kimi_model, flags_off, LLM::AI::StreamOptions.new))
    payload["messages"].as_a.none? { |msg| msg["tools"]? }.should be_true

    compat = LLM::AI::Compat.new(max_tokens_field: :max_completion_tokens, supports_mid_convo_tool_additions: true)
    model = LLM::AI::Model.new("kimi-k3", "Kimi K3", "kimi-coding", "http://127.0.0.1", LLM::AI::ApiKind::OpenaiCompletions,
      [LLM::AI::InputKind::Text], 256_000, 8192, true,
      LLM::AI::ModelCost.new(1.2, 4.0, 0.15, 1.2, nil),
      {"high" => "high", "off" => nil}, false, nil, compat)
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(model, flags_off, LLM::AI::StreamOptions.new))
    payload["messages"].as_a.none? { |msg| msg["tools"]? }.should be_true
  end

  it "maps finish reasons" do
    body = sse_body([final_chunk("length", usage_json(5, 2))])
    api = MockApi.new.serve(body).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, nil)
      stream.result.stop_reason.should eq LLM::AI::StopReason::Length
    ensure
      api.close
    end
  end

  it "infers stop when finish_reason is missing and unsupported" do
    no_finish = {"choices" => [{"index" => 0, "delta" => {"content" => "x"}, "finish_reason" => JSON::Any.new(nil)}]}.to_json
    body = sse_body([no_finish, "[DONE]"])
    api = MockApi.new.serve(body).start
    begin
      compat = LLM::AI::Compat.new(supports_finish_reason: false)
      model = LLM::AI::Model.new("m", "m", "p", "http://127.0.0.1:#{api.port}", LLM::AI::ApiKind::OpenaiCompletions,
        [LLM::AI::InputKind::Text], 1000, 1000, false, LLM::AI::ModelCost.new(1.0, 1.0, 0.1, 1.0, nil),
        compat: compat)
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, nil)
      stream.result.stop_reason.should eq LLM::AI::StopReason::Stop
    ensure
      api.close
    end
  end

  it "aborts mid-stream with partial content" do
    body = sse_body([content_chunk("hello"), content_chunk(" "), content_chunk("world")])
    api = MockApi.new.serve(body).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      abort = LLM::AI::AbortHandle.new
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, abort)
      deltas = 0
      terminal = nil
      stream.each do |event|
        case event
        when LLM::AI::StreamEvent::TextDelta
          deltas += 1
          abort.abort if deltas >= 2
        when LLM::AI::StreamEvent::Error
          terminal = event
        end
      end
      terminal.not_nil!.reason.should eq :aborted
      result = stream.result
      result.stop_reason.should eq LLM::AI::StopReason::Aborted
      result.content.select(LLM::AI::TextContent).first.not_nil!.text.should eq "hello "
    ensure
      api.close
    end
  end

  it "retries a 500 then succeeds" do
    ok = sse_body([content_chunk("ok"), final_chunk("stop", usage_json(2, 1))])
    api = ScriptedApi.new([{500, {} of String => String, "boom"}, {200, {"Content-Type" => "text/event-stream"}, ok}]).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new(max_retries: 1), auth_result, nil)
      result = stream.result
      result.content.select(LLM::AI::TextContent).first.not_nil!.text.should eq "ok"
      api.requests.should eq 2
    ensure
      api.close
    end
  end

  it "prefers chunk usage over choice usage" do
    both = %({"choices":[{"index":0,"delta":{},"finish_reason":null,"usage":{"prompt_tokens":1,"completion_tokens":2}}],"usage":{"prompt_tokens":100,"completion_tokens":7}})
    stop = %({"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]})
    body = sse_body([both, stop])
    api = MockApi.new.serve(body).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, nil)
      result = stream.result
      result.usage.not_nil!.input.should eq 100
      result.usage.not_nil!.output.should eq 7
    ensure
      api.close
    end
  end

  it "falls back to choice usage when chunk usage is absent" do
    choice_usage = %({"choices":[{"index":0,"delta":{},"finish_reason":null,"usage":{"prompt_tokens":30,"completion_tokens":4}}]})
    stop = %({"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]})
    body = sse_body([choice_usage, stop])
    api = MockApi.new.serve(body).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, nil)
      result = stream.result
      result.usage.not_nil!.input.should eq 30
      result.usage.not_nil!.output.should eq 4
    ensure
      api.close
    end
  end

  it "sends an empty tools array when replaying tool history without context tools" do
    assistant = LLM::AI::AssistantMessage.new(
      [LLM::AI::ToolCall.new("t1", "lookup", JSON.parse("{}"))] of LLM::AI::ContentBlock, "kimi", "kimi-k3", Time.utc)
    result = LLM::AI::ToolResultMessage.new("t1", "lookup", [LLM::AI::TextContent.new("found")] of LLM::AI::ContentBlock, Time.utc)
    context = LLM::AI::Context.new([assistant, result] of LLM::AI::Message)
    ok = sse_body([final_chunk("stop", usage_json(2, 1))])
    api = ScriptedApi.new([{200, {"Content-Type" => "text/event-stream"}, ok}]).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, context, LLM::AI::StreamOptions.new, auth_result, nil)
      stream.result.stop_reason.should eq LLM::AI::StopReason::Stop
      payload = JSON.parse(api.request_log.first[2])
      payload["tools"].as_a.empty?.should be_true
    ensure
      api.close
    end

    with_tools = LLM::AI::Context.new([assistant] of LLM::AI::Message, tools: [LLM::AI::Tool.new("lookup", "desc", JSON.parse("{}"))])
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(deepseek_model, with_tools, LLM::AI::StreamOptions.new))
    payload["tools"].as_a.size.should eq 1
  end

  it "replays a thinking-only assistant turn as text" do
    assistant = LLM::AI::AssistantMessage.new(
      [LLM::AI::ThinkingContent.new("Let me think")] of LLM::AI::ContentBlock, "kimi", "kimi-k3", Time.utc)
    context = LLM::AI::Context.new([assistant] of LLM::AI::Message)
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(kimi_model, context, LLM::AI::StreamOptions.new))
    message = payload["messages"][0]
    message["role"].should eq "assistant"
    message["content"].as_a.first["type"].should eq "text"
    message["content"].as_a.first["text"].should eq "Let me think"
    message.as_h.has_key?("reasoning_content").should be_false
  end

  it "streams reasoning_details, merges deltas, and replays them" do
    think = {"choices" => [{"index" => 0, "delta" => {"reasoning_content" => "thinking "}, "finish_reason" => JSON::Any.new(nil)}]}.to_json
    details1 = {"choices" => [{"index" => 0, "delta" => {"reasoning_details" => [
      {"type" => "reasoning.text", "text" => "a"},
      {"type" => "reasoning.text", "text" => "b", "signature" => "sig1"},
    ]}, "finish_reason" => JSON::Any.new(nil)}]}.to_json
    details2 = {"choices" => [{"index" => 0, "delta" => {"reasoning_details" => [
      {"type" => "reasoning.text", "text" => "c"},
      {"type" => "reasoning.summary", "summary" => "s"},
      {"type" => "reasoning.encrypted", "data" => "enc"},
      {"type" => "reasoning.text", "text" => "d"},
      {"type" => "reasoning.text"},
    ]}, "finish_reason" => JSON::Any.new(nil)}]}.to_json
    body = sse_body([think, details1, details2, final_chunk("stop", usage_json(5, 2))])
    api = MockApi.new.serve(body).start
    begin
      model = kimi_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, nil)
      events = [] of LLM::AI::StreamEvent
      stream.each { |event| events << event }
      events.any?(LLM::AI::StreamEvent::ThinkingStart).should be_true
      events.any?(LLM::AI::StreamEvent::ThinkingDelta).should be_true
      events.any?(LLM::AI::StreamEvent::ThinkingEnd).should be_true
      result = stream.result
      block = result.content.select(LLM::AI::ThinkingContent).first.not_nil!
      block.thinking.should eq "thinking "
      merged = JSON.parse(%([{"type":"reasoning.text","text":"abc","signature":"sig1"},{"type":"reasoning.summary","summary":"s"},{"type":"reasoning.encrypted","data":"enc"},{"type":"reasoning.text","text":"d"}]))
      JSON.parse(block.thinking_signature.not_nil!).should eq merged
      result.reasoning_details.should eq merged
      replay = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(kimi_model, LLM::AI::Context.new([result] of LLM::AI::Message), LLM::AI::StreamOptions.new))
      replay["messages"][0]["reasoning_details"].should eq merged
      replay["messages"][0].as_h.has_key?("reasoning_content").should be_false
    ensure
      api.close
    end
  end

  it "replays tool results with image placeholders and a synthetic user message" do
    with_text = LLM::AI::ToolResultMessage.new("t0", "txt", [LLM::AI::TextContent.new("a"), LLM::AI::TextContent.new("b")] of LLM::AI::ContentBlock, Time.utc)
    image_only = LLM::AI::ToolResultMessage.new("t1", "shot", [LLM::AI::ImageContent.new("aGVsbG8=", "image/png")] of LLM::AI::ContentBlock, Time.utc)
    empty = LLM::AI::ToolResultMessage.new("t2", "empty", [] of LLM::AI::ContentBlock, Time.utc)
    context = LLM::AI::Context.new([with_text, image_only, empty] of LLM::AI::Message)
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(vision_model, context, LLM::AI::StreamOptions.new))
    messages = payload["messages"].as_a
    messages.size.should eq 5
    messages[0]["role"].should eq "tool"
    messages[0]["content"].should eq "a\nb"
    messages[0]["name"].should eq "txt"
    messages[1]["content"].should eq "(see attached image)"
    messages[1]["name"].should eq "shot"
    messages[2]["content"].should eq "(no tool output)"
    messages[2]["name"].should eq "empty"
    messages[3]["role"].should eq "assistant"
    messages[3]["content"].should eq "I have processed the tool results."
    messages[4]["role"].should eq "user"
    messages[4]["content"][0]["text"].should eq "Attached image(s) from tool result:"
    messages[4]["content"][1]["image_url"]["url"].should eq "data:image/png;base64,aGVsbG8="
    messages[4]["content"].as_a.size.should eq 2
  end

  it "omits tool result extras without compat flags or image input" do
    tool_result = LLM::AI::ToolResultMessage.new("t1", "shot", [LLM::AI::ImageContent.new("aGVsbG8=", "image/png")] of LLM::AI::ContentBlock, Time.utc)
    context = LLM::AI::Context.new([tool_result] of LLM::AI::Message)
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(deepseek_model, context, LLM::AI::StreamOptions.new))
    messages = payload["messages"].as_a
    messages.size.should eq 1
    messages[0]["content"].should eq "(see attached image)"
    messages[0].as_h.has_key?("name").should be_false
  end

  it "sets duration_ms on the final message" do
    body = sse_body([content_chunk("hi"), final_chunk("stop", usage_json(2, 1))])
    api = MockApi.new.serve(body).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, nil)
      events = [] of LLM::AI::StreamEvent
      stream.each { |event| events << event }
      done = events.last.as(LLM::AI::StreamEvent::Done)
      done.message.duration_ms.should_not be_nil
      done.message.duration_ms.not_nil!.should be >= 0
    ensure
      api.close
    end
  end

  it "produces byte-identical payloads for the same context" do
    tool = LLM::AI::Tool.new("lookup", "look up", JSON.parse(%({"type":"object","properties":{"q":{"type":"string"}}})))
    context = LLM::AI::Context.new([LLM::AI::UserMessage.new("hi", Time.utc)] of LLM::AI::Message, tools: [tool])
    a = LLM::AI::Api::OpenAICompletions.build_payload(deepseek_model, context, LLM::AI::StreamOptions.new)
    b = LLM::AI::Api::OpenAICompletions.build_payload(deepseek_model, context, LLM::AI::StreamOptions.new)
    a.should eq b
  end

  it "serializes tool parameters with sorted keys regardless of insertion order" do
    tool_a = LLM::AI::Tool.new("t", "d", JSON.parse(%({"type":"object","properties":{"b":{"type":"string"},"a":{"type":"number"}}})))
    tool_b = LLM::AI::Tool.new("t", "d", JSON.parse(%({"properties":{"a":{"type":"number"},"b":{"type":"string"}},"type":"object"})))
    a = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(deepseek_model, LLM::AI::Context.new([] of LLM::AI::Message, tools: [tool_a]), LLM::AI::StreamOptions.new))
    b = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(deepseek_model, LLM::AI::Context.new([] of LLM::AI::Message, tools: [tool_b]), LLM::AI::StreamOptions.new))
    a["tools"][0]["function"]["parameters"].to_json.should eq b["tools"][0]["function"]["parameters"].to_json
  end

  it "replays a deepseek assistant turn with text, reasoning, and tool calls" do
    assistant = LLM::AI::AssistantMessage.new(
      [
        LLM::AI::ThinkingContent.new("let me think", "reasoning_content"),
        LLM::AI::TextContent.new("hello"),
        LLM::AI::ToolCall.new("t1", "lookup", JSON.parse(%({"q":"x"}))),
      ] of LLM::AI::ContentBlock,
      "deepseek", "deepseek-chat", Time.utc)
    context = LLM::AI::Context.new([assistant] of LLM::AI::Message)
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(deepseek_model, context, LLM::AI::StreamOptions.new))
    message = payload["messages"][0]
    message["content"].should eq "hello"
    message["reasoning_content"].should eq "let me think"
    message["tool_calls"][0]["function"]["arguments"].should eq JSON.parse(%({"q":"x"}))
  end

  it "emits moonshot payload fields behind compat flags" do
    compat = LLM::AI::Compat.new(
      max_tokens_field: :max_completion_tokens,
      supports_response_format: true,
      supports_stop: true,
      supports_prediction: true,
      supports_logprobs: true,
      supports_prompt_cache_key: true,
      supports_safety_identifier: true,
    )
    model = LLM::AI::Model.new("kimi-k3", "Kimi K3", "moonshot", "http://127.0.0.1", LLM::AI::ApiKind::OpenaiCompletions,
      [LLM::AI::InputKind::Text], 256_000, 8192, true,
      LLM::AI::ModelCost.new(1.2, 4.0, 0.15, 1.2, nil),
      {"high" => "high", "off" => nil}, false, nil, compat)
    options = LLM::AI::StreamOptions.new(
      response_format: JSON.parse(%({"type":"json_object"})),
      stop: ["END", "STOP"],
      prediction: JSON.parse(%({"type":"content","content":"expected"})),
      logprobs: true,
      top_logprobs: 5,
      prompt_cache_key: "session-1",
      prompt_cache_options: JSON.parse(%({"retention":"1h"})),
      safety_identifier: "user-42",
    )
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(model, user_context, options))
    payload["response_format"]["type"].should eq "json_object"
    payload["stop"].as_a.map(&.as_s).should eq ["END", "STOP"]
    payload["prediction"]["content"].should eq "expected"
    payload["logprobs"].should be_true
    payload["top_logprobs"].should eq 5
    payload["prompt_cache_key"].should eq "session-1"
    payload["prompt_cache_options"]["retention"].should eq "1h"
    payload["safety_identifier"].should eq "user-42"
  end

  it "omits moonshot payload fields without compat flags" do
    options = LLM::AI::StreamOptions.new(
      response_format: JSON.parse(%({"type":"json_object"})),
      stop: ["END"],
      prediction: JSON.parse(%({"type":"content","content":"expected"})),
      logprobs: true,
      top_logprobs: 5,
      prompt_cache_key: "session-1",
      prompt_cache_options: JSON.parse(%({"retention":"1h"})),
      safety_identifier: "user-42",
    )
    payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(deepseek_model, user_context, options))
    ["response_format", "stop", "prediction", "logprobs", "top_logprobs",
     "prompt_cache_key", "prompt_cache_options", "safety_identifier"].each do |key|
      payload.as_h.has_key?(key).should be_false
    end
  end

  it "collects logprobs from stream chunks" do
    logprobs_chunk = {"choices" => [{"index" => 0, "delta" => {"content" => "hi"}, "finish_reason" => JSON::Any.new(nil),
                                     "logprobs" => JSON.parse(%({"content":[{"token":"hi","logprob":-0.1}]}))}]}.to_json
    body = sse_body([logprobs_chunk, final_chunk("stop", usage_json(2, 1))])
    api = MockApi.new.serve(body).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, nil)
      result = stream.result
      result.logprobs.not_nil![0]["content"][0]["token"].should eq "hi"
    ensure
      api.close
    end
  end

  it "leaves logprobs nil when the stream carries none" do
    body = sse_body([content_chunk("hi"), final_chunk("stop", usage_json(2, 1))])
    api = MockApi.new.serve(body).start
    begin
      model = deepseek_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::OpenAICompletions.stream(model, user_context, LLM::AI::StreamOptions.new, auth_result, nil)
      stream.result.logprobs.should be_nil
    ensure
      api.close
    end
  end
end
