# spec/oauth_kimi_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def device_auth_response(interval : Int32 = 1) : Tuple(Int32, Hash(String, String), String)
  body = {
    "device_code"               => "device-1",
    "user_code"                 => "ABCD-1234",
    "verification_uri"          => "https://auth.kimi.com/device",
    "verification_uri_complete" => "https://auth.kimi.com/device?user_code=ABCD-1234",
    "interval"                  => interval,
    "expires_in"                => 60,
  }.to_json
  {200, {"Content-Type" => "application/json"}, body}
end

private def token_error_response(error : String) : Tuple(Int32, Hash(String, String), String)
  {400, {"Content-Type" => "application/json"}, {"error" => error}.to_json}
end

private def token_success_response : Tuple(Int32, Hash(String, String), String)
  {200, {"Content-Type" => "application/json"}, {"access_token" => "access-k", "refresh_token" => "refresh-k", "expires_in" => 1800}.to_json}
end

private def kimi_host(api : ScriptedApi) : String
  "http://127.0.0.1:#{api.port}"
end

private def run_kimi_login(interaction, api, interval_seconds = 1, slow_down_seconds = 1) : Channel(LLM::AI::OAuthCredential | Exception)
  result = Channel(LLM::AI::OAuthCredential | Exception).new
  spawn do
    result.send LLM::AI::Auth::Kimi.login(
      interaction,
      auth_host: kimi_host(api),
      interval_seconds: interval_seconds,
      slow_down_seconds: slow_down_seconds,
      wait_before_first_poll: true,
    )
  rescue ex
    result.send ex
  end
  result
end

describe LLM::AI::Auth::Kimi do
  it "requests device authorization and notifies the user code" do
    api = ScriptedApi.new([device_auth_response, token_success_response]).start
    begin
      interaction = RecordingInteraction.new([] of String)
      result      = run_kimi_login(interaction, api)
      result.receive.should be_a(LLM::AI::OAuthCredential)
      device = interaction.events.first.should be_a(LLM::AI::Auth::DeviceCode)
      device.user_code.should eq "ABCD-1234"
      device.verification_uri.should eq "https://auth.kimi.com/device?user_code=ABCD-1234"
      first = api.request_log[0]
      first[0].should eq "POST"
      first[1].should eq "/api/oauth/device_authorization"
      HTTP::Params.parse(first[2])["client_id"].should eq "17e5f671-d194-4dfb-9706-5516cb48c098"
      token_request = api.request_log[1]
      notify_time   = interaction.event_times[0]
      (token_request[3] - notify_time).should be >= 900.milliseconds
    ensure
      api.close
    end
  end

  it "polls pending then succeeds" do
    api = ScriptedApi.new([device_auth_response, token_error_response("authorization_pending"), token_success_response]).start
    begin
      interaction = RecordingInteraction.new([] of String)
      result      = run_kimi_login(interaction, api)
      credential  = result.receive.should be_a(LLM::AI::OAuthCredential)
      credential.access.should eq "access-k"
      credential.refresh.should eq "refresh-k"
      expected = Time.utc.to_unix_ms + 1_800_000
      (credential.expires - expected).abs.should be < 2000
      api.requests.should eq 3
    ensure
      api.close
    end
  end

  it "honors slow_down" do
    api = ScriptedApi.new([device_auth_response, token_error_response("authorization_pending"), token_error_response("slow_down"), token_success_response]).start
    begin
      interaction = RecordingInteraction.new([] of String)
      result      = run_kimi_login(interaction, api)
      result.receive.should be_a(LLM::AI::OAuthCredential)
      gap = api.request_log[3][3] - api.request_log[2][3]
      gap.should be >= 1.9.seconds
    ensure
      api.close
    end
  end

  it "fails on expired_token with restart message" do
    api = ScriptedApi.new([device_auth_response, token_error_response("expired_token")]).start
    begin
      interaction = RecordingInteraction.new([] of String)
      result      = run_kimi_login(interaction, api)
      error       = result.receive.should be_a(Exception)
      (error.message || "").should contain "restart"
    ensure
      api.close
    end
  end

  it "fails on access_denied" do
    api = ScriptedApi.new([device_auth_response, token_error_response("access_denied")]).start
    begin
      interaction = RecordingInteraction.new([] of String)
      result      = run_kimi_login(interaction, api)
      error       = result.receive.should be_a(Exception)
      (error.message || "").should contain "denied"
    ensure
      api.close
    end
  end

  it "refresh retries transient failures up to 3 times" do
    api = ScriptedApi.new([
      {429, {} of String => String, "busy"},
      {429, {} of String => String, "busy"},
      token_success_response,
    ]).start
    begin
      credential = LLM::AI::Auth::Kimi.refresh("refresh-k", kimi_host(api))
      credential.access.should eq "access-k"
      api.requests.should eq 3
      first = api.request_log[0]
      first[1].should eq "/api/oauth/token"
      params = HTTP::Params.parse(first[2])
      params["grant_type"].should eq "refresh_token"
      params["refresh_token"].should eq "refresh-k"
    ensure
      api.close
    end
  end

  it "refresh fails permanently on invalid_grant" do
    api = ScriptedApi.new([token_error_response("invalid_grant")]).start
    begin
      expect_raises(LLM::AI::Auth::DeadCredential) do
        LLM::AI::Auth::Kimi.refresh("refresh-k", kimi_host(api))
      end
      api.requests.should eq 1
    ensure
      api.close
    end
  end
end
