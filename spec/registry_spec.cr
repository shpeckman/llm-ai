# spec/registry_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def faux_context : LLM::AI::Context
  LLM::AI::Context.new([] of LLM::AI::Message, nil)
end

describe LLM::AI::Models do
  it "registers the built-in providers" do
    models = LLM::AI::Models.build
    models.providers.should contain "faux"
    models.providers.should contain "deepseek"
    models.providers.should contain "anthropic"
    models.providers.should contain "kimi-coding"
    models.providers.should contain "moonshot"
    models.providers.should contain "moonshot-anthropic"
  end

  it "looks up catalog models per provider" do
    models = LLM::AI::Models.build
    models.model("deepseek", "deepseek-flash").provider.should eq "deepseek"
    models.model("anthropic", "claude-opus-4-5").api.should eq LLM::AI::ApiKind::AnthropicMessages
    models.model("anthropic", "claude-opus-5-5").compat.force_adaptive_thinking.should be_true
    models.model("kimi-coding", "kimi-for-coding").provider.should eq "kimi-coding"
    models.model("kimi-coding", "kimi-for-coding").base_url.should eq "https://api.kimi.com/coding/v1"
    models.model("moonshot", "kimi-k3").provider.should eq "moonshot"
    models.model("moonshot", "kimi-k3").base_url.should eq "https://api.moonshot.ai/v1"
    models.model("moonshot-anthropic", "kimi-k3").api.should eq LLM::AI::ApiKind::AnthropicMessages
    models.model("moonshot-anthropic", "kimi-k3").base_url.should eq "https://api.moonshot.ai/anthropic"
    models.model("moonshot-anthropic", "kimi-k3").compat.anthropic_auth_scheme.should eq :bearer
  end

  it "resolves deepseek, kimi, and moonshot ambient env keys" do
    models = LLM::AI::Models.build
    with_temp_store do |store, _, _|
      with_env({"DEEPSEEK_API_KEY" => "sk-ds"}) do
        result = LLM::AI::Auth.resolve("deepseek", models.provider("deepseek").auth, store, LLM::AI::Auth::AuthContext.default)
        result.auth.api_key.should eq "sk-ds"
        result.source.should eq "ambient env"
      end
      with_env({"KIMI_API_KEY" => "sk-kimi"}) do
        result = LLM::AI::Auth.resolve("kimi-coding", models.provider("kimi-coding").auth, store, LLM::AI::Auth::AuthContext.default)
        result.auth.api_key.should eq "sk-kimi"
      end
      with_env({"MOONSHOT_API_KEY" => "sk-moonshot"}) do
        result = LLM::AI::Auth.resolve("moonshot", models.provider("moonshot").auth, store, LLM::AI::Auth::AuthContext.default)
        result.auth.api_key.should eq "sk-moonshot"
      end
    end
  end

  it "resolves the anthropic auth token as a bearer header" do
    models = LLM::AI::Models.build
    with_temp_store do |store, _, _|
      with_env({"ANTHROPIC_AUTH_TOKEN" => "tok"}) do
        result = LLM::AI::Auth.resolve("anthropic", models.provider("anthropic").auth, store, LLM::AI::Auth::AuthContext.default)
        result.auth.api_key.should be_nil
        result.auth.headers.not_nil!["Authorization"].should eq "Bearer tok"
        result.source.should eq "ambient env"
      end
    end
  end

  it "builds payloads for catalog models" do
    models = LLM::AI::Models.build
    context = LLM::AI::Context.new([LLM::AI::UserMessage.new([LLM::AI::TextContent.new("hi")] of LLM::AI::ContentBlock, Time.utc)] of LLM::AI::Message)
    openai_payload = JSON.parse(LLM::AI::Api::OpenAICompletions.build_payload(models.model("deepseek", "deepseek-flash"), context, LLM::AI::StreamOptions.new))
    openai_payload["model"].should eq "deepseek-flash"
    anthropic_payload = JSON.parse(LLM::AI::Api::AnthropicMessages.build_payload(models.model("anthropic", "claude-opus-4-5"), context, LLM::AI::StreamOptions.new, false))
    anthropic_payload["model"].should eq "claude-opus-4-5"
    anthropic_payload["stream"].should be_true
  end

  it "logs in and out through the ergonomic auth surface" do
    with_temp_store do |store, _, _|
      models = LLM::AI::Models.build(store)
      interaction = RecordingInteraction.new(["sk-ergo"])
      LLM::AI::Auth.login(models, "deepseek", :api_key, interaction)
      store.read("deepseek").should eq LLM::AI::ApiKeyCredential.new("sk-ergo")
      LLM::AI::Auth.logout(models, "deepseek")
      store.read("deepseek").should be_nil
    end
  end

  it "looks up models" do
    models = LLM::AI::Models.build
    models.model("faux", "faux-chat").id.should eq "faux-chat"
    expect_raises(LLM::AI::ModelsError, "Unknown model") do
      models.model("faux", "nope")
    end
    expect_raises(LLM::AI::ModelsError, "Unknown provider") do
      models.model("nope", "nope")
    end
  end

  it "streams from faux and yields the event protocol" do
    models = LLM::AI::Models.build
    stream = models.stream(models.model("faux", "faux-chat"), faux_context)
    events = [] of LLM::AI::StreamEvent
    stream.each { |event| events << event }
    events.first.should be_a(LLM::AI::StreamEvent::Start)
    deltas = events.select(LLM::AI::StreamEvent::TextDelta)
    deltas.map(&.text).should eq ["hello"]
    terminal = events.last.should be_a(LLM::AI::StreamEvent::Done)
    terminal.reason.should eq LLM::AI::StopReason::Stop
    terminal.message.duration_ms.should_not be_nil
    result = stream.result
    result.stop_reason.should eq LLM::AI::StopReason::Stop
    result.content.should eq [LLM::AI::TextContent.new("hello")]
  end

  it "chat collects the final message" do
    models = LLM::AI::Models.build
    message = models.chat(models.model("faux", "faux-chat"), faux_context)
    message.content.should eq [LLM::AI::TextContent.new("hello")]
    message.stop_reason.should eq LLM::AI::StopReason::Stop
  end

  it "returns the partial message on abort" do
    models = LLM::AI::Models.build
    abort = LLM::AI::AbortHandle.new
    stream = models.stream(models.model("faux", "faux-chat"), faux_context, nil, abort)
    saw_text = false
    stream.each do |event|
      case event
      when LLM::AI::StreamEvent::TextDelta
        saw_text = true
        abort.abort
      end
    end
    saw_text.should be_true
    result = stream.result
    result.stop_reason.should eq LLM::AI::StopReason::Aborted
    result.content.should eq [LLM::AI::TextContent.new("hello")]
    result.duration_ms.should_not be_nil
  end

  it "uses the api_key stream option as an auth override" do
    with_temp_store do |store, _, _|
      models = LLM::AI::Models.new(store, LLM::AI::Auth::AuthContext.new(->(_name : String) { "ambient".as(String?) }, ->(_path : String) { false }))
      seen = [] of String?
      model = LLM::AI::Model.new("m", "m", "capture", "http://x", LLM::AI::ApiKind::OpenaiCompletions,
        [LLM::AI::InputKind::Text], 1000, 1000, false, LLM::AI::ModelCost.new(0.0, 0.0, 0.0, 0.0))
      models.register(LLM::AI::Provider.new("capture", "Capture", "http://x", {} of String => String,
        LLM::AI::Auth::ProviderAuth.new(LLM::AI::Auth::ApiKeyAuth.new("Key", ["CAPTURE_KEY"])), [model],
        ->(_model : LLM::AI::Model, _context : LLM::AI::Context, _options : LLM::AI::StreamOptions, auth : LLM::AI::Auth::AuthResult, abort : LLM::AI::AbortHandle?) do
          seen << auth.auth.api_key
          stream = LLM::AI::MessageStream.new(abort)
          spawn { stream.finish(LLM::AI::StreamEvent::Done.new(LLM::AI::StopReason::Stop, LLM::AI::AssistantMessage.new([] of LLM::AI::ContentBlock, "capture", "m", Time.utc, stop_reason: LLM::AI::StopReason::Stop))) }
          stream
        end))
      models.chat(model, faux_context, LLM::AI::StreamOptions.new(api_key: "explicit"))
      models.chat(model, faux_context, LLM::AI::StreamOptions.new(api_key: ""))
      models.chat(model, faux_context)
      seen.should eq ["explicit", "ambient", "ambient"]
    end
  end

  it "surfaces error events as ModelsError from result" do
    models = LLM::AI::Models.build
    stream = models.stream(models.model("faux", "faux-error"), faux_context)
    error = expect_raises(LLM::AI::ModelsError, "faux error") do
      stream.result
    end
    error.kind.should eq "stream"
  end
end
