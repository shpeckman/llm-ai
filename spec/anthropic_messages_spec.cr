# spec/anthropic_messages_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def anthropic_model(base_url : String = "http://127.0.0.1") : LLM::AI::Model
  LLM::AI::Model.new("claude-test", "claude-test", "anthropic", base_url, LLM::AI::ApiKind::AnthropicMessages,
    [LLM::AI::InputKind::Text], 200_000, 8192, true,
    LLM::AI::ModelCost.new(5.0, 25.0, 0.5, 6.25, 10.0),
    {"high" => "high", "off" => nil}, true, nil, LLM::AI::Compat.new)
end

private def anthropic_model_with_compat(compat : LLM::AI::Compat, base_url : String = "http://127.0.0.1") : LLM::AI::Model
  LLM::AI::Model.new("claude-test", "claude-test", "anthropic", base_url, LLM::AI::ApiKind::AnthropicMessages,
    [LLM::AI::InputKind::Text], 200_000, 8192, true,
    LLM::AI::ModelCost.new(5.0, 25.0, 0.5, 6.25, 10.0),
    {"high" => "high", "off" => nil}, true, nil, compat)
end

private def anthropic_context : LLM::AI::Context
  LLM::AI::Context.new([LLM::AI::UserMessage.new([LLM::AI::TextContent.new("hi")] of LLM::AI::ContentBlock, Time.utc)] of LLM::AI::Message)
end

private def api_key_auth : LLM::AI::Auth::AuthResult
  LLM::AI::Auth::AuthResult.new(LLM::AI::Auth::ModelAuth.new("sk-ant-test"), "ambient env")
end

private def oauth_auth : LLM::AI::Auth::AuthResult
  LLM::AI::Auth::AuthResult.new(LLM::AI::Auth::ModelAuth.new("sk-ant-oat-token"), "oauth")
end

private def anthropic_sse(events : Array(Tuple(String, String))) : String
  events.map { |name, data| "event: #{name}\ndata: #{data}\n\n" }.join
end

private def message_start(usage : String? = nil) : Tuple(String, String)
  data = {
    "type"    => "message_start",
    "message" => {
      "id"    => "msg_1",
      "model" => "claude-test",
      "usage" => usage ? JSON.parse(usage) : JSON.parse("{\"input_tokens\":10,\"output_tokens\":3,\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":1}"),
    },
  }.to_json
  {"message_start", data}
end

private def message_stop : Tuple(String, String)
  {"message_stop", "{\"type\":\"message_stop\"}"}
end

private def end_turn_delta : Tuple(String, String)
  {"message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":8,\"output_tokens_details\":{\"thinking_tokens\":4}}}"}
end

private def block_start(index : Int32, block : String) : Tuple(String, String)
  {"content_block_start", "{\"type\":\"content_block_start\",\"index\":#{index},\"content_block\":#{block}}"}
end

private def block_delta(index : Int32, delta : String) : Tuple(String, String)
  {"content_block_delta", "{\"type\":\"content_block_delta\",\"index\":#{index},\"delta\":#{delta}}"}
end

private def block_stop(index : Int32) : Tuple(String, String)
  {"content_block_stop", "{\"type\":\"content_block_stop\",\"index\":#{index}}"}
end

describe LLM::AI::Api::AnthropicMessages do
  it "streams text, thinking, and a tool call with usage" do
    body = anthropic_sse([
      message_start,
      block_start(0, "{\"type\":\"text\",\"text\":\"\"}"),
      block_delta(0, "{\"type\":\"text_delta\",\"text\":\"hello\"}"),
      block_delta(0, "{\"type\":\"text_delta\",\"text\":\" world\"}"),
      block_stop(0),
      block_start(1, "{\"type\":\"thinking\",\"thinking\":\"hmm\",\"signature\":\"\"}"),
      block_delta(1, "{\"type\":\"thinking_delta\",\"thinking\":\" let me think\"}"),
      block_delta(1, "{\"type\":\"signature_delta\",\"signature\":\"sig1\"}"),
      block_stop(1),
      block_start(2, "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"get_weather\",\"input\":{}}"),
      block_delta(2, "{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\\\"pari\"}"),
      block_delta(2, "{\"type\":\"input_json_delta\",\"partial_json\":\"s\\\"}\"}"),
      block_stop(2),
      end_turn_delta,
      message_stop,
    ])
    api = MockApi.new.serve(body).start
    begin
      model  = anthropic_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new, api_key_auth, nil)
      events = [] of LLM::AI::StreamEvent
      stream.each { |event| events << event }
      events.first.should be_a(LLM::AI::StreamEvent::Start)
      events.select(LLM::AI::StreamEvent::TextDelta).map(&.text).join.should eq "hello world"
      events.any?(LLM::AI::StreamEvent::ThinkingStart).should be_true
      events.any?(LLM::AI::StreamEvent::ThinkingEnd).should be_true
      events.any?(LLM::AI::StreamEvent::ToolCallEnd).should be_true
      result = stream.result
      result.stop_reason.should eq LLM::AI::StopReason::Stop
      result.raw_stop_reason.should eq "end_turn"
      text = result.content.select(LLM::AI::TextContent).first.not_nil!
      text.text.should eq "hello world"
      thinking = result.content.select(LLM::AI::ThinkingContent).first.not_nil!
      thinking.thinking.should eq "hmm let me think"
      thinking.thinking_signature.should eq "sig1"
      tool = result.content.select(LLM::AI::ToolCall).first.not_nil!
      tool.arguments.should eq JSON.parse("{\"city\":\"paris\"}")
      usage = result.usage.not_nil!
      usage.input.should eq 10
      usage.output.should eq 8
      usage.cache_read.should eq 2
      usage.cache_write.should eq 1
      usage.reasoning.should eq 4
      usage.total_tokens.should eq 21
      usage.cost.should eq LLM::AI::Pricing.calculate(model, usage)
      result.duration_ms.should_not be_nil
    ensure
      api.close
    end
  end

  it "maps max_tokens and tool_use stop reasons" do
    body = anthropic_sse([
      message_start,
      {"message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}"},
      message_stop,
    ])
    api = MockApi.new.serve(body).start
    begin
      model  = anthropic_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new, api_key_auth, nil)
      stream.result.stop_reason.should eq LLM::AI::StopReason::Length
    ensure
      api.close
    end

    body = anthropic_sse([
      message_start,
      {"message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}"},
      message_stop,
    ])
    api = MockApi.new.serve(body).start
    begin
      model  = anthropic_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new, api_key_auth, nil)
      stream.result.stop_reason.should eq LLM::AI::StopReason::ToolUse
    ensure
      api.close
    end
  end

  it "maps refusal to an error event with the explanation" do
    body = anthropic_sse([
      message_start,
      {"message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\",\"stop_details\":{\"explanation\":\"blocked by policy\"}}}"},
      message_stop,
    ])
    api = MockApi.new.serve(body).start
    begin
      model    = anthropic_model("http://127.0.0.1:#{api.port}")
      stream   = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new, api_key_auth, nil)
      terminal = nil
      stream.each do |event|
        terminal = event if event.is_a?(LLM::AI::StreamEvent::Error)
      end
      terminal.not_nil!.reason.should eq :error
      terminal.not_nil!.message.error_message.should eq "blocked by policy"
      error = expect_raises(LLM::AI::ModelsError, "blocked by policy") do
        stream.result
      end
      error.kind.should eq "stream"
    ensure
      api.close
    end

    body = anthropic_sse([
      message_start,
      {"message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\",\"stop_details\":{}}}"},
      message_stop,
    ])
    api = MockApi.new.serve(body).start
    begin
      model    = anthropic_model("http://127.0.0.1:#{api.port}")
      stream   = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new, api_key_auth, nil)
      terminal = nil
      stream.each do |event|
        terminal = event if event.is_a?(LLM::AI::StreamEvent::Error)
      end
      terminal.not_nil!.message.error_message.should eq "The model refused to complete the request"
    ensure
      api.close
    end
  end

  it "throws on event: error and ignores unknown events" do
    body = anthropic_sse([
      {"ping", "{\"type\":\"ping\"}"},
      message_start,
      {"error", "{\"type\":\"error\",\"error\":{\"message\":\"boom\"}}"},
    ])
    api = MockApi.new.serve(body).start
    begin
      model    = anthropic_model("http://127.0.0.1:#{api.port}")
      stream   = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new, api_key_auth, nil)
      terminal = nil
      stream.each do |event|
        terminal = event if event.is_a?(LLM::AI::StreamEvent::Error)
      end
      terminal.not_nil!.reason.should eq :error
      expect_raises(LLM::AI::ModelsError, "boom") do
        stream.result
      end
    ensure
      api.close
    end
  end

  it "aborts mid-stream with partial content" do
    body = anthropic_sse([
      message_start,
      block_start(0, "{\"type\":\"text\",\"text\":\"\"}"),
      block_delta(0, "{\"type\":\"text_delta\",\"text\":\"hello\"}"),
      block_delta(0, "{\"type\":\"text_delta\",\"text\":\" \"}"),
      block_delta(0, "{\"type\":\"text_delta\",\"text\":\"world\"}"),
    ])
    api = MockApi.new.serve(body).start
    begin
      model    = anthropic_model("http://127.0.0.1:#{api.port}")
      abort    = LLM::AI::AbortHandle.new
      stream   = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new, api_key_auth, abort)
      deltas   = 0
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
    ok  = anthropic_sse([message_start, end_turn_delta, message_stop])
    api = ScriptedApi.new([{500, {} of String => String, "boom"}, {200, {"Content-Type" => "text/event-stream"}, ok}]).start
    begin
      model  = anthropic_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new(max_retries: 1), api_key_auth, nil)
      stream.result.stop_reason.should eq LLM::AI::StopReason::Stop
      api.requests.should eq 2
    ensure
      api.close
    end
  end

  it "builds the anthropic request payload" do
    tool_use = LLM::AI::ToolCall.new("t1", "get_weather", JSON.parse("{\"city\":\"paris\"}"))
    assistant = LLM::AI::AssistantMessage.new(
      [LLM::AI::TextContent.new("sure"), LLM::AI::ThinkingContent.new("hmm", "sig"), tool_use] of LLM::AI::ContentBlock,
      "anthropic", "claude-test", Time.utc)
    results = [
      LLM::AI::ToolResultMessage.new("t1", "get_weather", [LLM::AI::TextContent.new("sunny")] of LLM::AI::ContentBlock, Time.utc),
      LLM::AI::ToolResultMessage.new("t2", "lookup", [LLM::AI::TextContent.new("found")] of LLM::AI::ContentBlock, Time.utc),
    ]
    tools = [
      LLM::AI::Tool.new("get_weather", "weather lookup", JSON.parse("{\"type\":\"object\"}")),
      LLM::AI::Tool.new("lookup", "look things up", JSON.parse("{\"type\":\"object\"}")),
    ]
    context = LLM::AI::Context.new(
      [LLM::AI::SystemMessage.new("you are a bot", Time.utc), LLM::AI::UserMessage.new("hi", Time.utc), assistant] of LLM::AI::Message +
      results.map { |result| result.as(LLM::AI::Message) },
      "be nice", tools)
    payload = JSON.parse(LLM::AI::Api::AnthropicMessages.build_payload(
      anthropic_model, context, LLM::AI::StreamOptions.new(thinking_level: "high", user_id: "u1"), false))
    payload["model"].should eq "claude-test"
    payload["stream"].should eq true
    payload["max_tokens"].as_i.should eq 8192
    system = payload["system"].as_a
    system.size.should eq 2
    system[0]["text"].should eq "be nice"
    system[1]["text"].should eq "you are a bot"
    system[0]["cache_control"]["type"].should eq "ephemeral"
    system[1]["cache_control"]["type"].should eq "ephemeral"
    messages = payload["messages"].as_a
    messages[0]["role"].should eq "user"
    messages[0]["content"].should eq "hi"
    assistant_wire = messages[1]
    assistant_wire["role"].should eq "assistant"
    blocks = assistant_wire["content"].as_a
    blocks[0]["type"].should eq "text"
    blocks[0]["text"].should eq "sure"
    blocks[1]["type"].should eq "thinking"
    blocks[1]["signature"].should eq "sig"
    blocks[2]["type"].should eq "tool_use"
    blocks[2]["id"].should eq "t1"
    blocks[2]["input"]["city"].should eq "paris"
    results_wire = messages[2]
    results_wire["role"].should eq "user"
    tool_results = results_wire["content"].as_a
    tool_results.size.should eq 2
    tool_results[0]["tool_use_id"].should eq "t1"
    tool_results[1]["tool_use_id"].should eq "t2"
    tool_results[1]["cache_control"]["type"].should eq "ephemeral"
    tools_wire = payload["tools"].as_a
    tools_wire.size.should eq 2
    tools_wire[0]["name"].should eq "get_weather"
    tools_wire[0]["input_schema"]["type"].should eq "object"
    tools_wire[0]["eager_input_streaming"].should eq true
    tools_wire[1]["cache_control"]["type"].should eq "ephemeral"
    payload["thinking"]["type"].should eq "enabled"
    payload["thinking"]["budget_tokens"].as_i.should eq 7168
    payload["metadata"]["user_id"].should eq "u1"
    payload.as_h.has_key?("temperature").should be_false
  end

  it "replays redacted thinking and converts signatureless thinking to text" do
    assistant = LLM::AI::AssistantMessage.new(
      [LLM::AI::ThinkingContent.new("[Reasoning redacted]", "enc", true), LLM::AI::ThinkingContent.new("thought", nil)] of LLM::AI::ContentBlock,
      "anthropic", "claude-test", Time.utc)
    context = LLM::AI::Context.new([assistant] of LLM::AI::Message)
    payload = JSON.parse(LLM::AI::Api::AnthropicMessages.build_payload(anthropic_model, context, LLM::AI::StreamOptions.new, false))
    blocks  = payload["messages"][0]["content"].as_a
    blocks[0]["type"].should eq "redacted_thinking"
    blocks[0]["data"].should eq "enc"
    blocks[1]["type"].should eq "text"
    blocks[1]["text"].should eq "thought"
  end

  it "holds back mid-conversation system messages until the next assistant message" do
    assistant = LLM::AI::AssistantMessage.new([LLM::AI::TextContent.new("ok")] of LLM::AI::ContentBlock, "anthropic", "claude-test", Time.utc)
    update    = LLM::AI::SystemMessage.new("sys", Time.utc, {"rules" => "be kind"} of String => String?)
    context   = LLM::AI::Context.new([LLM::AI::UserMessage.new("hi", Time.utc), update, assistant] of LLM::AI::Message)
    payload   = JSON.parse(LLM::AI::Api::AnthropicMessages.build_payload(anthropic_model, context, LLM::AI::StreamOptions.new, false))
    messages  = payload["messages"].as_a
    messages[0]["role"].should eq "user"
    messages[1]["role"].should eq "system"
    messages[1]["content"].should eq "sys\n\nUpdated system prompt section \"rules\":\n\nbe kind"
    messages[2]["role"].should eq "assistant"
  end

  it "sends OAuth headers, the identity block, and canonicalized tool names" do
    body = anthropic_sse([
      message_start,
      block_start(0, "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{}}"),
      block_delta(0, "{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}"),
      block_stop(0),
      end_turn_delta,
      message_stop,
    ])
    api = MockApi.new.serve(body).start
    begin
      model = anthropic_model("http://127.0.0.1:#{api.port}")
      context = LLM::AI::Context.new(
        [LLM::AI::UserMessage.new("run a command", Time.utc)] of LLM::AI::Message,
        nil, [LLM::AI::Tool.new("bash", "run bash", JSON.parse("{\"type\":\"object\"}"))])
      stream  = LLM::AI::Api::AnthropicMessages.stream(model, context, LLM::AI::StreamOptions.new, oauth_auth, nil)
      result  = stream.result
      headers = api.last_headers.not_nil!
      headers["Authorization"].should eq "Bearer sk-ant-oat-token"
      headers["user-agent"].should eq "claude-cli/2.1.280"
      headers["x-app"].should eq "cli"
      headers["anthropic-beta"].should contain "claude-code-20250219"
      headers["anthropic-beta"].should contain "oauth-2025-04-20"
      request = JSON.parse(api.requests[0][2])
      request["system"][0]["text"].should eq "You are Claude Code, Anthropic's official CLI for Claude."
      request["tools"][0]["name"].should eq "Bash"
      tool = result.content.select(LLM::AI::ToolCall).first.not_nil!
      tool.name.should eq "bash"
      tool.arguments.should eq JSON.parse("{\"cmd\":\"ls\"}")
    ensure
      api.close
    end
  end

  it "sends x-api-key for non-OAuth auth" do
    body = anthropic_sse([message_start, end_turn_delta, message_stop])
    api  = MockApi.new.serve(body).start
    begin
      model  = anthropic_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new, api_key_auth, nil)
      stream.result.stop_reason.should eq LLM::AI::StopReason::Stop
      headers = api.last_headers.not_nil!
      headers["x-api-key"].should eq "sk-ant-test"
      headers.has_key?("Authorization").should be_false
    ensure
      api.close
    end
  end

  it "builds adaptive thinking params for 5.5 models" do
    compat = LLM::AI::Compat.new(force_adaptive_thinking: true)
    model = LLM::AI::Model.new("claude-opus-5-5", "claude-opus-5-5", "anthropic", "http://127.0.0.1",
      LLM::AI::ApiKind::AnthropicMessages, [LLM::AI::InputKind::Text], 1_000_000, 128_000, true,
      LLM::AI::ModelCost.new(4.0, 20.0, 0.2, 5.0, 8.0),
      {"off" => nil, "minimal" => "low", "low" => "low", "medium" => "medium", "high" => "high"} of String => String?,
      true, nil, compat)
    payload = JSON.parse(LLM::AI::Api::AnthropicMessages.build_payload(
      model, anthropic_context, LLM::AI::StreamOptions.new(thinking_level: "medium"), false))
    payload["thinking"]["type"].should eq "adaptive"
    payload["thinking"]["display"].should eq "summarized"
    payload["output_config"]["effort"].should eq "medium"
    payload.as_h.has_key?("budget_tokens").should be_false
    plain = JSON.parse(LLM::AI::Api::AnthropicMessages.build_payload(model, anthropic_context, LLM::AI::StreamOptions.new, false))
    plain.as_h.has_key?("thinking").should be_false
    plain.as_h.has_key?("output_config").should be_false
  end

  it "sends fallbacks, the fallback beta, and prices usage with the fallback cost" do
    fallback = LLM::AI::FallbackModel.new("anthropic", "claude-fallback", LLM::AI::ModelCost.new(1.0, 2.0, 0.3, 0.4, 0.8))
    compat   = LLM::AI::Compat.new(allowed_fallback_models: [fallback] of LLM::AI::FallbackModel)
    body = anthropic_sse([
      {"message_start", "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"claude-fallback\",\"usage\":{\"input_tokens\":10,\"output_tokens\":3,\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":1}}}"},
      end_turn_delta,
      message_stop,
    ])
    api = MockApi.new.serve(body).start
    begin
      model  = anthropic_model_with_compat(compat, "http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new, api_key_auth, nil)
      result = stream.result
      result.response_model.should eq "claude-fallback"
      usage = result.usage.not_nil!
      fallback_priced = LLM::AI::Model.new("claude-fallback", "claude-fallback", "anthropic", model.base_url,
        LLM::AI::ApiKind::AnthropicMessages, [LLM::AI::InputKind::Text], model.context_window, model.max_tokens,
        true, fallback.cost)
      usage.cost.should eq LLM::AI::Pricing.calculate(fallback_priced, usage)
      usage.cost.should_not eq LLM::AI::Pricing.calculate(model, usage)
      headers = api.last_headers.not_nil!
      headers["anthropic-beta"].should contain "server-side-fallback-2026-07-01"
      request = JSON.parse(api.requests[0][2])
      request["fallbacks"].as_a.size.should eq 1
      request["fallbacks"][0]["model"].should eq "claude-fallback"
    ensure
      api.close
    end
  end

  it "keeps the requested model cost when the response model is not a known fallback" do
    fallback = LLM::AI::FallbackModel.new("anthropic", "claude-fallback", LLM::AI::ModelCost.new(1.0, 2.0, 0.3, 0.4, 0.8))
    compat   = LLM::AI::Compat.new(allowed_fallback_models: [fallback] of LLM::AI::FallbackModel)
    body = anthropic_sse([
      {"message_start", "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"other-model\",\"usage\":{\"input_tokens\":10,\"output_tokens\":3,\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":1}}}"},
      end_turn_delta,
      message_stop,
    ])
    api = MockApi.new.serve(body).start
    begin
      model  = anthropic_model_with_compat(compat, "http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new, api_key_auth, nil)
      usage  = stream.result.usage.not_nil!
      usage.cost.should eq LLM::AI::Pricing.calculate(model, usage)
    ensure
      api.close
    end
  end

  it "throws on mid-output fallback blocks and ignores leading ones" do
    body = anthropic_sse([
      message_start,
      block_start(0, "{\"type\":\"text\",\"text\":\"\"}"),
      block_delta(0, "{\"type\":\"text_delta\",\"text\":\"hi\"}"),
      block_start(1, "{\"type\":\"fallback\",\"model\":\"other\"}"),
    ])
    api = MockApi.new.serve(body).start
    begin
      model    = anthropic_model("http://127.0.0.1:#{api.port}")
      stream   = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new, api_key_auth, nil)
      terminal = nil
      stream.each do |event|
        terminal = event if event.is_a?(LLM::AI::StreamEvent::Error)
      end
      terminal.not_nil!.reason.should eq :error
      expect_raises(LLM::AI::ModelsError, "Anthropic performed an unsupported mid-output model fallback") do
        stream.result
      end
    ensure
      api.close
    end

    body = anthropic_sse([
      message_start,
      block_start(0, "{\"type\":\"fallback\",\"model\":\"other\"}"),
      block_start(1, "{\"type\":\"text\",\"text\":\"\"}"),
      block_delta(1, "{\"type\":\"text_delta\",\"text\":\"ok\"}"),
      block_stop(1),
      end_turn_delta,
      message_stop,
    ])
    api = MockApi.new.serve(body).start
    begin
      model  = anthropic_model("http://127.0.0.1:#{api.port}")
      stream = LLM::AI::Api::AnthropicMessages.stream(model, anthropic_context, LLM::AI::StreamOptions.new, api_key_auth, nil)
      result = stream.result
      result.stop_reason.should eq LLM::AI::StopReason::Stop
      result.content.select(LLM::AI::TextContent).first.not_nil!.text.should eq "ok"
    ensure
      api.close
    end
  end

  it "sends managed effort betas, output_config, and per-message effort markers" do
    compat = LLM::AI::Compat.new(supports_mid_convo_effort: true)
    body = anthropic_sse([
      message_start,
      block_start(0, "{\"type\":\"text\",\"text\":\"\"}"),
      block_delta(0, "{\"type\":\"text_delta\",\"text\":\"hi\"}"),
      block_stop(0),
      end_turn_delta,
      message_stop,
    ])
    api = MockApi.new.serve(body).start
    begin
      model = anthropic_model_with_compat(compat, "http://127.0.0.1:#{api.port}")
      low = LLM::AI::AssistantMessage.new([LLM::AI::TextContent.new("one")] of LLM::AI::ContentBlock, "anthropic", "claude-test", Time.utc,
        api: "anthropic_messages", provider_thinking_level: "low")
      high = LLM::AI::AssistantMessage.new([LLM::AI::TextContent.new("two")] of LLM::AI::ContentBlock, "anthropic", "claude-test", Time.utc,
        api: "anthropic_messages", provider_thinking_level: "xhigh")
      foreign = LLM::AI::AssistantMessage.new([LLM::AI::TextContent.new("three")] of LLM::AI::ContentBlock, "anthropic", "claude-test", Time.utc,
        api: "openai_completions", provider_thinking_level: "low")
      context = LLM::AI::Context.new([
        LLM::AI::UserMessage.new("hi", Time.utc), low,
        LLM::AI::UserMessage.new("more", Time.utc), high,
        LLM::AI::UserMessage.new("again", Time.utc), foreign,
      ] of LLM::AI::Message)
      stream = LLM::AI::Api::AnthropicMessages.stream(model, context, LLM::AI::StreamOptions.new(temperature: 0.7, thinking_enabled: true), api_key_auth, nil)
      result = stream.result
      result.provider_thinking_level.should eq "high"
      headers = api.last_headers.not_nil!
      headers["anthropic-beta"].should contain "mid-conversation-output-config-2026-07-01"
      headers["anthropic-beta"].should contain "thinking-binding-controls-2026-08-01"
      request = JSON.parse(api.requests[0][2])
      request["output_config"]["effort"].should eq "high"
      request["thinking"]["type"].should eq "adaptive"
      request["thinking"]["display"].should eq "summarized"
      request["thinking"]["block_binding"]["prefix_mismatch_behavior"].should eq "drop_block"
      request.as_h.has_key?("temperature").should be_false
      messages = request["messages"].as_a
      messages.map { |message| message["role"].as_s }.should eq ["user", "system", "assistant", "user", "system", "assistant", "user", "assistant", "system"]
      messages[1]["output_config"]["effort"].should eq "low"
      messages[1]["content"].as_a.size.should eq 0
      messages[4]["output_config"]["effort"].should eq "xhigh"
      messages[8]["output_config"]["effort"].should eq "high"
      disabled = JSON.parse(LLM::AI::Api::AnthropicMessages.build_payload(model, anthropic_context, LLM::AI::StreamOptions.new(thinking_enabled: false), false))
      disabled.as_h.has_key?("thinking").should be_false
      disabled["output_config"]["effort"].should eq "high"
      omitted = JSON.parse(LLM::AI::Api::AnthropicMessages.build_payload(model, anthropic_context, LLM::AI::StreamOptions.new(thinking_enabled: true, thinking_display: "omitted"), false))
      omitted["thinking"]["display"].should eq "omitted"
    ensure
      api.close
    end
  end

  it "sends native tool additions and removals with the inline-tools beta" do
    compat = LLM::AI::Compat.new(supports_mid_convo_system_messages: true, supports_mid_convo_tool_changes: true)
    body   = anthropic_sse([message_start, end_turn_delta, message_stop])
    api    = MockApi.new.serve(body).start
    begin
      model = anthropic_model_with_compat(compat, "http://127.0.0.1:#{api.port}")
      update = LLM::AI::SystemMessage.new(
        "tools changed", Time.utc,
        tools_added: [
          LLM::AI::Tool.new("calc", "calculate", JSON.parse("{\"type\":\"object\"}")),
          LLM::AI::Tool.new("weather", "weather v2", JSON.parse("{\"type\":\"object\"}")),
        ] of LLM::AI::Tool,
        tools_removed: [
          LLM::AI::ToolReference.new("weather"),
          LLM::AI::ToolReference.new("old"),
        ] of LLM::AI::ToolReference)
      context = LLM::AI::Context.new(
        [LLM::AI::UserMessage.new("hi", Time.utc), update,
         LLM::AI::AssistantMessage.new([LLM::AI::TextContent.new("ok")] of LLM::AI::ContentBlock, "anthropic", "claude-test", Time.utc)] of LLM::AI::Message,
        nil, [LLM::AI::Tool.new("weather", "weather", JSON.parse("{\"type\":\"object\"}"))] of LLM::AI::Tool)
      stream = LLM::AI::Api::AnthropicMessages.stream(model, context, LLM::AI::StreamOptions.new, api_key_auth, nil)
      stream.result.stop_reason.should eq LLM::AI::StopReason::Stop
      headers = api.last_headers.not_nil!
      headers["anthropic-beta"].should contain "inline-tools-2026-09-15"
      request = JSON.parse(api.requests[0][2])
      tools   = request["tools"].as_a
      tools.size.should eq 2
      tools[0]["name"].should eq "weather"
      tools[1]["name"].should eq "__pi_deferred_placeholder__"
      tools[1]["defer_loading"].should eq true
      tools[1]["input_schema"]["type"].should eq "object"
      system_message = request["messages"].as_a[1]
      system_message["role"].should eq "system"
      blocks = system_message["content"].as_a
      blocks.size.should eq 4
      blocks[0]["type"].should eq "text"
      blocks[0]["text"].should eq "tools changed"
      blocks[1]["type"].should eq "tool_removal"
      blocks[1]["tool"]["type"].should eq "tool_reference"
      blocks[1]["tool"]["name"].should eq "old"
      blocks[2]["type"].should eq "tool_addition"
      blocks[2]["tool"]["type"].should eq "tool_definition"
      blocks[2]["tool"]["definition"]["name"].should eq "calc"
      blocks[2]["tool"]["definition"]["input_schema"]["type"].should eq "object"
      blocks[3]["type"].should eq "tool_addition"
      blocks[3]["tool"]["definition"]["name"].should eq "weather"
    ensure
      api.close
    end
  end
end
