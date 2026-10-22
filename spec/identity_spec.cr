# spec/identity_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def model(provider : String, base_url : String) : LLM::AI::Model
  LLM::AI::Model.new("m", "m", provider, base_url, LLM::AI::ApiKind::OpenaiCompletions,
    [LLM::AI::InputKind::Text], 1000, 1000, false, LLM::AI::ModelCost.new(0.0, 0.0, 0.0, 0.0))
end

private def attribution : LLM::AI::ClientAttribution
  LLM::AI::ClientAttribution.new("acme", "https://acme.example", ["cli-agent", "editor"])
end

describe LLM::AI::Identity do
  it "describes the library, runtime, and platform by default" do
    agent = LLM::AI::Identity.user_agent(nil)
    agent.should eq "llm-ai/#{LLM::AI::VERSION} (#{LLM::AI::Identity::PLATFORM}; crystal/#{Crystal::VERSION}; #{LLM::AI::Identity::ARCH})"
    LLM::AI::VERSION.should match /\A\d+\.\d+\.\d+/
  end

  it "supports short, versioned, and custom user agents" do
    LLM::AI::Identity.user_agent(LLM::AI::ClientIdentity.new(user_agent: :short)).should eq "llm-ai"
    LLM::AI::Identity.user_agent(LLM::AI::ClientIdentity.new(version: "9.9.9")).should start_with "llm-ai/9.9.9 ("
    LLM::AI::Identity.user_agent(LLM::AI::ClientIdentity.new(user_agent: "acme/1.0")).should eq "acme/1.0"
  end

  it "sends no attribution headers without an attribution or to other providers" do
    LLM::AI::Identity.attribution_headers(model("openrouter", "https://openrouter.ai/api/v1"), nil).should be_empty
    identity = LLM::AI::ClientIdentity.new(attribution: attribution)
    LLM::AI::Identity.attribution_headers(model("deepseek", "https://api.deepseek.com"), identity).should be_empty
  end

  it "maps attribution to each provider's headers" do
    identity = LLM::AI::ClientIdentity.new(attribution: attribution)
    LLM::AI::Identity.attribution_headers(model("custom", "https://openrouter.ai/api/v1"), identity).should eq({
      "HTTP-Referer"            => "https://acme.example",
      "X-OpenRouter-Title"      => "acme",
      "X-OpenRouter-Categories" => "cli-agent,editor",
    })
    LLM::AI::Identity.attribution_headers(model("custom", "https://integrate.api.nvidia.com/v1"), identity).should eq({"X-BILLING-INVOKE-ORIGIN" => "Acme"})
    LLM::AI::Identity.attribution_headers(model("opencode", "https://example.com"), identity).should eq({"x-opencode-client" => "acme"})
  end

  it "combines the user agent and attribution" do
    identity = LLM::AI::ClientIdentity.new(user_agent: :short, attribution: attribution)
    LLM::AI::Identity.headers(model("nvidia", "https://x"), identity).should eq({"User-Agent" => "llm-ai", "X-BILLING-INVOKE-ORIGIN" => "Acme"})
  end

  it "round-trips through JSON" do
    identity = LLM::AI::ClientIdentity.new(user_agent: :short, attribution: attribution, version: "1.0.0")
    LLM::AI::ClientIdentity.from_json(identity.to_json).should eq identity
    custom = LLM::AI::ClientIdentity.new(user_agent: "acme/2")
    LLM::AI::ClientIdentity.from_json(custom.to_json).user_agent.should eq "acme/2"
  end

  it "sends identity headers below explicit headers on OpenAI-compatible requests" do
    body = "data: #{({"choices" => [{"index" => 0, "delta" => {"content" => "ok"}, "finish_reason" => "stop"}]}).to_json}\n\ndata: [DONE]\n\n"
    api = MockApi.new.serve(body).start
    begin
      target = model("deepseek", "http://127.0.0.1:#{api.port}")
      context = LLM::AI::Context.new([LLM::AI::UserMessage.new("hi", Time.utc)] of LLM::AI::Message)
      auth = LLM::AI::Auth::AuthResult.new(LLM::AI::Auth::ModelAuth.new("key"))
      options = LLM::AI::StreamOptions.new(identity: LLM::AI::ClientIdentity.new(user_agent: :short))
      LLM::AI::Api::OpenAICompletions.stream(target, context, options, auth, nil).result
      api.last_headers.not_nil!["User-Agent"].should eq "llm-ai"
      overridden = LLM::AI::StreamOptions.new(headers: {"user-agent" => "mine"})
      LLM::AI::Api::OpenAICompletions.stream(target, context, overridden, auth, nil).result
      api.last_headers.not_nil!.get("User-Agent").should eq ["mine"]
    ensure
      api.close
    end
  end
end
