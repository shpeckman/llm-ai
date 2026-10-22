# spec/auth_resolve_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def oauth_cred(expires : Int64) : LLM::AI::OAuthCredential
  LLM::AI::OAuthCredential.new("refresh-t", "access-t", expires)
end

private def api_key_auth(*env_vars : String) : LLM::AI::Auth::ApiKeyAuth
  LLM::AI::Auth::ApiKeyAuth.new("Test API key", env_vars.to_a)
end

private def oauth_auth(refresh_proc : Proc(String, LLM::AI::Auth::AuthHosts?, LLM::AI::OAuthCredential)) : LLM::AI::Auth::OAuthAuth
  LLM::AI::Auth::OAuthAuth.new(
    "Test OAuth", true, "Sign in with Test",
    ->(_interaction : LLM::AI::Auth::Interaction, _hosts : LLM::AI::Auth::AuthHosts?) { raise "login not expected" },
    refresh_proc,
  )
end

private def provider_auth(api_key : LLM::AI::Auth::ApiKeyAuth? = nil, oauth : LLM::AI::Auth::OAuthAuth? = nil) : LLM::AI::Auth::ProviderAuth
  LLM::AI::Auth::ProviderAuth.new(api_key, oauth)
end

describe LLM::AI::Auth do
  it "override api key wins over stored and env" do
    with_temp_store do |store, _, _|
      with_env({"TEST_API_KEY" => "env-key"}) do
        store.modify("deepseek") { LLM::AI::ApiKeyCredential.new("stored-key") }
        auth = provider_auth(api_key_auth("TEST_API_KEY"))
        result = LLM::AI::Auth.resolve("deepseek", auth, store, LLM::AI::Auth::AuthContext.default,
          LLM::AI::Auth::AuthOverrides.new("override-key", nil))
        result.source.should eq "override"
        result.auth.api_key.should eq "override-key"
      end
    end
  end

  it "stored oauth credential is returned fresh when not expiring" do
    with_temp_store do |store, _, _|
      calls = 0
      refresh = ->(_token : String, _hosts : LLM::AI::Auth::AuthHosts?) {
        calls += 1
        oauth_cred(Time.utc.to_unix_ms + 3_600_000)
      }
      store.modify("anthropic") { oauth_cred(Time.utc.to_unix_ms + 600_000) }
      auth = provider_auth(oauth: oauth_auth(refresh))
      result = LLM::AI::Auth.resolve("anthropic", auth, store, LLM::AI::Auth::AuthContext.default)
      result.source.should eq "oauth"
      result.auth.api_key.should eq "access-t"
      calls.should eq 0
    end
  end

  it "refreshes an expiring oauth credential exactly once under concurrency" do
    with_temp_store do |store, _, _|
      calls = 0
      refresh = ->(_token : String, _hosts : LLM::AI::Auth::AuthHosts?) {
        calls += 1
        oauth_cred(Time.utc.to_unix_ms + 3_600_000)
      }
      store.modify("anthropic") { oauth_cred(Time.utc.to_unix_ms + 1_000) }
      auth = provider_auth(oauth: oauth_auth(refresh))
      done = Channel(Nil).new
      10.times do
        spawn do
          LLM::AI::Auth.resolve("anthropic", auth, store, LLM::AI::Auth::AuthContext.default)
          done.send nil
        end
      end
      10.times { done.receive }
      calls.should eq 1
      stored = store.read("anthropic").as(LLM::AI::OAuthCredential)
      stored.access.should eq "access-t"
      stored.expires.should be > Time.utc.to_unix_ms + 3_000_000
    end
  end

  it "deletes the credential when refresh fails permanently" do
    with_temp_store do |store, _, _|
      with_env({"TEST_API_KEY" => "env-key"}) do
        refresh = ->(_token : String, _hosts : LLM::AI::Auth::AuthHosts?) {
          raise LLM::AI::Auth::DeadCredential.new("dead")
        }
        store.modify("deepseek") { oauth_cred(Time.utc.to_unix_ms + 1_000) }
        auth = provider_auth(api_key_auth("TEST_API_KEY"), oauth_auth(refresh))
        result = LLM::AI::Auth.resolve("deepseek", auth, store, LLM::AI::Auth::AuthContext.default)
        result.source.should eq "ambient env"
        result.auth.api_key.should eq "env-key"
        store.read("deepseek").should be_nil
      end
    end
  end

  it "keeps the credential and raises on a transient refresh failure without env fallthrough" do
    with_temp_store do |store, _, _|
      with_env({"TEST_API_KEY" => "env-key"}) do
        refresh = ->(_token : String, _hosts : LLM::AI::Auth::AuthHosts?) {
          raise LLM::AI::Auth::Error.new("transient failure")
        }
        store.modify("deepseek") { oauth_cred(Time.utc.to_unix_ms + 1_000) }
        auth = provider_auth(api_key_auth("TEST_API_KEY"), oauth_auth(refresh))
        expect_raises(LLM::AI::Auth::Error, "transient failure") do
          LLM::AI::Auth.resolve("deepseek", auth, store, LLM::AI::Auth::AuthContext.default)
        end
        stored = store.read("deepseek").as(LLM::AI::OAuthCredential)
        stored.access.should eq "access-t"
      end
    end
  end

  it "keeps the credential and raises when the refresh times out" do
    with_temp_store do |store, _, _|
      with_env({"TEST_API_KEY" => "env-key"}) do
        refresh = ->(_token : String, _hosts : LLM::AI::Auth::AuthHosts?) {
          sleep 5.seconds
          oauth_cred(Time.utc.to_unix_ms + 3_600_000)
        }
        store.modify("deepseek") { oauth_cred(Time.utc.to_unix_ms + 1_000) }
        auth = provider_auth(api_key_auth("TEST_API_KEY"), oauth_auth(refresh))
        overrides = LLM::AI::Auth::AuthOverrides.new(nil, nil, refresh_timeout: 50.milliseconds)
        expect_raises(LLM::AI::Auth::Error, "timed out") do
          LLM::AI::Auth.resolve("deepseek", auth, store, LLM::AI::Auth::AuthContext.default, overrides)
        end
        stored = store.read("deepseek").as(LLM::AI::OAuthCredential)
        stored.access.should eq "access-t"
      end
    end
  end

  it "stored api key beats env var" do
    with_temp_store do |store, _, _|
      with_env({"TEST_API_KEY" => "env-key"}) do
        store.modify("deepseek") { LLM::AI::ApiKeyCredential.new("stored-key") }
        auth = provider_auth(api_key_auth("TEST_API_KEY"))
        result = LLM::AI::Auth.resolve("deepseek", auth, store, LLM::AI::Auth::AuthContext.default)
        result.source.should eq "stored credential"
        result.auth.api_key.should eq "stored-key"
      end
    end
  end

  it "ANTHROPIC_AUTH_TOKEN becomes a Bearer header" do
    with_temp_store do |store, _, _|
      with_env({"ANTHROPIC_AUTH_TOKEN" => "token-1"}) do
        auth = provider_auth(api_key_auth("ANTHROPIC_API_KEY"))
        result = LLM::AI::Auth.resolve("anthropic", auth, store, LLM::AI::Auth::AuthContext.default)
        result.source.should eq "ambient env"
        result.auth.api_key.should be_nil
        result.auth.headers.not_nil!["Authorization"].should eq "Bearer token-1"
      end
    end
  end

  it "login with api_key prompts secret and stores" do
    with_temp_store do |store, _, _|
      interaction = RecordingInteraction.new(["sk-abc"])
      auth = provider_auth(api_key_auth("TEST_API_KEY"))
      LLM::AI::Auth.login("deepseek", auth, store, interaction, :api_key)
      store.read("deepseek").should eq LLM::AI::ApiKeyCredential.new("sk-abc")
    end
  end

  it "logout deletes" do
    with_temp_store do |store, _, _|
      store.modify("deepseek") { LLM::AI::ApiKeyCredential.new("k") }
      LLM::AI::Auth.logout("deepseek", store)
      store.read("deepseek").should be_nil
    end
  end
end
