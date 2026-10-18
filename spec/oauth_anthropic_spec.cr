# spec/oauth_anthropic_spec.cr
require "./spec_helper"
require "digest/sha256"
require "base64"
require "../src/llm-ai"

def token_ok_body(expires_in : Int32 = 3600) : String
  {"access_token" => "access-1", "refresh_token" => "refresh-1", "expires_in" => expires_in}.to_json
end

private def mock_hosts(api : MockApi) : LLM::AI::Auth::AuthHosts
  LLM::AI::Auth::AuthHosts.new(
    authorize_url: "https://claude.ai/oauth/authorize",
    token_url: "http://127.0.0.1:#{api.port}/v1/oauth/token",
  )
end

private def run_login(interaction : LLM::AI::Auth::Interaction, no_browser : Bool, hosts : LLM::AI::Auth::AuthHosts) : Channel(LLM::AI::OAuthCredential | Exception)
  result = Channel(LLM::AI::OAuthCredential | Exception).new
  spawn do
    begin
      result.send LLM::AI::Auth::Anthropic.login(interaction, no_browser, hosts)
    rescue ex
      result.send ex
    end
  end
  result
end

private class BlockingInteraction < LLM::AI::Auth::Interaction
  getter auth_urls : Array(LLM::AI::Auth::AuthUrl)

  def initialize
    @auth_urls = [] of LLM::AI::Auth::AuthUrl
  end

  def prompt(kind : LLM::AI::Auth::PromptKind, message : String) : String
    sleep
    ""
  end

  def notify(event : LLM::AI::Auth::AuthEvent) : Nil
    if url_event = event.as?(LLM::AI::Auth::AuthUrl)
      @auth_urls << url_event
    end
  end
end

private class PasteInteraction < LLM::AI::Auth::Interaction
  def initialize(@kind : Symbol)
    @auth_urls = [] of LLM::AI::Auth::AuthUrl
  end

  def prompt(kind : LLM::AI::Auth::PromptKind, message : String) : String
    params = URI.parse(@auth_urls.first.not_nil!.url).query_params
    state = params["state"].not_nil!
    case @kind
    when :code_state
      "pasted-code##{state}"
    when :query
      "code=pasted-code&state=#{state}"
    when :redirect_url
      redirect = URI.parse(params["redirect_uri"].not_nil!)
      "http://#{redirect.host}:#{redirect.port}#{redirect.path}?code=pasted-code&state=#{state}"
    else
      raise "unknown paste kind"
    end
  end

  def notify(event : LLM::AI::Auth::AuthEvent) : Nil
    if url_event = event.as?(LLM::AI::Auth::AuthUrl)
      @auth_urls << url_event
    end
  end
end

describe LLM::AI::Auth::PKCE do
  it "generates a 43-char base64url verifier and SHA-256 challenge" do
    verifier, challenge = LLM::AI::Auth::PKCE.generate
    verifier.size.should eq 43
    verifier.should match(/\A[A-Za-z0-9_-]+\z/)
    challenge.should eq Base64.urlsafe_encode(Digest::SHA256.digest(verifier), padding: false)
  end
end

describe LLM::AI::Auth::Anthropic do
  it "builds the authorize URL with all params" do
    api = MockApi.new.serve(token_ok_body, 200, "application/json").start
    begin
      interaction = RecordingInteraction.new(prompt_results: ["code"])
      result = run_login(interaction, true, mock_hosts(api))
      result.receive.should be_a(LLM::AI::OAuthCredential)
      url = interaction.auth_urls.first.url
      params = URI.parse(url).query_params
      params["client_id"].should eq "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
      params["response_type"].should eq "code"
      params["code_challenge_method"].should eq "S256"
      params["scope"].should contain "user:inference"
      params["state"].not_nil!.should_not be_empty
      params["code_challenge"].not_nil!.should_not be_empty
    ensure
      api.close
    end
  end

  it "exchanges the code and stores a 5-minute margin" do
    api = MockApi.new.serve(token_ok_body, 200, "application/json").start
    begin
      interaction = RecordingInteraction.new(prompt_results: ["auth-code-123"])
      result = run_login(interaction, true, mock_hosts(api))
      credential = result.receive.should be_a(LLM::AI::OAuthCredential)
      body = JSON.parse(api.requests.first[2])
      body["grant_type"].should eq "authorization_code"
      body["code"].should eq "auth-code-123"
      body["code_verifier"].as_s.should_not be_empty
      credential.access.should eq "access-1"
      credential.refresh.should eq "refresh-1"
      expected = Time.utc.to_unix_ms + 3_600_000 - 300_000
      (credential.expires - expected).abs.should be < 2000
    ensure
      api.close
    end
  end

  it "rejects a state mismatch from manual input" do
    api = MockApi.new.serve(token_ok_body, 200, "application/json").start
    begin
      interaction = RecordingInteraction.new(prompt_results: ["code#wrongstate"])
      result = run_login(interaction, true, mock_hosts(api))
      error = result.receive.should be_a(Exception)
      (error.message || "").should contain "state"
      api.requests.should be_empty
    ensure
      api.close
    end
  end

  it "serves the callback and exchanges via browser flow" do
    api = MockApi.new.serve(token_ok_body, 200, "application/json").start
    begin
      interaction = BlockingInteraction.new
      result = run_login(interaction, false, mock_hosts(api))
      url_event = nil
      200.times do
        url_event = interaction.auth_urls.first?
        break if url_event
        sleep 10.milliseconds
      end
      url_event = url_event.not_nil!
      params = URI.parse(url_event.url).query_params
      callback = "http://127.0.0.1:53692/callback?code=callback-code&state=#{params["state"]}"
      callback_uri = URI.parse(callback)
      client = HTTP::Client.new("127.0.0.1", 53692)
      begin
        response = client.get(callback_uri.request_target)
        response.status_code.should eq 200
      ensure
        client.close
      end
      credential = result.receive.should be_a(LLM::AI::OAuthCredential)
      body = JSON.parse(api.requests.first[2])
      body["code"].should eq "callback-code"
    ensure
      api.close
    end
  end

  it "uses the copy-code redirect uri" do
    api = MockApi.new.serve(token_ok_body, 200, "application/json").start
    begin
      interaction = RecordingInteraction.new(prompt_results: ["code"])
      result = run_login(interaction, true, mock_hosts(api))
      result.receive.should be_a(LLM::AI::OAuthCredential)
      url = interaction.auth_urls.first.url
      URI.parse(url).query_params["redirect_uri"].should eq "https://platform.claude.com/oauth/code/callback"
    ensure
      api.close
    end
  end

  it "refreshes with grant_type refresh_token" do
    api = MockApi.new.serve(token_ok_body, 200, "application/json").start
    begin
      credential = LLM::AI::Auth::Anthropic.refresh("refresh-1", mock_hosts(api))
      credential.access.should eq "access-1"
      api.last_headers.not_nil!["Content-Type"].should eq "application/json"
      body = JSON.parse(api.requests.first[2])
      body["grant_type"].should eq "refresh_token"
      body["refresh_token"].should eq "refresh-1"
    ensure
      api.close
    end
  end

  it "accepts a bare code pasted manually in the browser flow" do
    api = MockApi.new.serve(token_ok_body, 200, "application/json").start
    begin
      interaction = RecordingInteraction.new(prompt_results: ["manual-code-1"])
      result = run_login(interaction, false, mock_hosts(api))
      credential = result.receive.should be_a(LLM::AI::OAuthCredential)
      body = JSON.parse(api.requests.first[2])
      body["grant_type"].should eq "authorization_code"
      body["code"].should eq "manual-code-1"
      credential.access.should eq "access-1"
    ensure
      api.close
    end
  end

  it "accepts code#state pasted manually in the browser flow" do
    api = MockApi.new.serve(token_ok_body, 200, "application/json").start
    begin
      interaction = PasteInteraction.new(:code_state)
      result = run_login(interaction, false, mock_hosts(api))
      credential = result.receive.should be_a(LLM::AI::OAuthCredential)
      body = JSON.parse(api.requests.first[2])
      body["code"].should eq "pasted-code"
      body["code_verifier"].as_s.should_not be_empty
      credential.access.should eq "access-1"
    ensure
      api.close
    end
  end

  it "accepts code=... query input pasted manually in the browser flow" do
    api = MockApi.new.serve(token_ok_body, 200, "application/json").start
    begin
      interaction = PasteInteraction.new(:query)
      result = run_login(interaction, false, mock_hosts(api))
      credential = result.receive.should be_a(LLM::AI::OAuthCredential)
      body = JSON.parse(api.requests.first[2])
      body["code"].should eq "pasted-code"
      credential.access.should eq "access-1"
    ensure
      api.close
    end
  end

  it "accepts a full redirect URL pasted manually in the browser flow" do
    api = MockApi.new.serve(token_ok_body, 200, "application/json").start
    begin
      interaction = PasteInteraction.new(:redirect_url)
      result = run_login(interaction, false, mock_hosts(api))
      credential = result.receive.should be_a(LLM::AI::OAuthCredential)
      body = JSON.parse(api.requests.first[2])
      body["code"].should eq "pasted-code"
      body["redirect_uri"].as_s.should contain "/callback"
      credential.access.should eq "access-1"
    ensure
      api.close
    end
  end

  it "fails the browser flow on a state mismatch in the pasted input" do
    api = MockApi.new.serve(token_ok_body, 200, "application/json").start
    begin
      interaction = RecordingInteraction.new(prompt_results: ["pasted-code#wrong-state"])
      result = run_login(interaction, false, mock_hosts(api))
      error = result.receive.should be_a(Exception)
      (error.message || "").should contain "state"
      api.requests.should be_empty
    ensure
      api.close
    end
  end

  it "refresh raises DeadCredential on 401 with invalid_grant body" do
    api = MockApi.new.serve({"error" => "invalid_grant"}.to_json, 401, "application/json").start
    begin
      expect_raises(LLM::AI::Auth::DeadCredential) do
        LLM::AI::Auth::Anthropic.refresh("refresh-1", mock_hosts(api))
      end
      api.requests.size.should eq 1
    ensure
      api.close
    end
  end

  it "refresh raises DeadCredential on 403 without invalid_grant in the body" do
    api = MockApi.new.serve({"error" => "access_denied"}.to_json, 403, "application/json").start
    begin
      expect_raises(LLM::AI::Auth::DeadCredential) do
        LLM::AI::Auth::Anthropic.refresh("refresh-1", mock_hosts(api))
      end
    ensure
      api.close
    end
  end

  it "refresh wraps other http failures as Error" do
    api = MockApi.new.serve("boom", 500, "text/plain").start
    begin
      expect_raises(LLM::AI::Auth::Error) do
        LLM::AI::Auth::Anthropic.refresh("refresh-1", mock_hosts(api))
      end
    ensure
      api.close
    end
  end
end
