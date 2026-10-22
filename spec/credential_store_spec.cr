# spec/credential_store_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def oauth(refresh : String, access : String, expires : Int64, extra : Hash(String, JSON::Any) = Hash(String, JSON::Any).new) : LLM::AI::OAuthCredential
  LLM::AI::OAuthCredential.new(refresh, access, expires, extra)
end

describe LLM::AI::FileCredentialStore do
  it "round-trips an oauth credential" do
    with_temp_store do |store, _, _|
      credential = oauth("refresh-token", "access-token", 1_734_200_000_000_i64)
      store.modify("kimi-coding") { credential }
      store.read("kimi-coding").should eq credential
    end
  end

  it "lists provider ids and types" do
    with_temp_store do |store, _, _|
      store.modify("deepseek") { LLM::AI::ApiKeyCredential.new("sk-1") }
      store.modify("anthropic") { oauth("r", "a", 1_i64) }
      infos = store.list.sort_by(&.provider_id)
      infos.should eq [
        LLM::AI::CredentialInfo.new("anthropic", "oauth"),
        LLM::AI::CredentialInfo.new("deepseek", "api_key"),
      ]
    end
  end

  it "modify passes the current value and stores the returned value" do
    with_temp_store do |store, _, _|
      seen = [] of LLM::AI::Credential?
      store.modify("p") do |current|
        seen << current
        LLM::AI::ApiKeyCredential.new("first")
      end
      store.modify("p") do |current|
        seen << current
        LLM::AI::ApiKeyCredential.new("second")
      end
      seen[0].should be_nil
      seen[1].should eq LLM::AI::ApiKeyCredential.new("first")
      store.read("p").should eq LLM::AI::ApiKeyCredential.new("second")
    end
  end

  it "delete removes" do
    with_temp_store do |store, _, _|
      store.modify("p") { LLM::AI::ApiKeyCredential.new("k") }
      store.read("p").should_not be_nil
      store.delete("p")
      store.read("p").should be_nil
      store.list.should be_empty
    end
  end

  it "concurrent modifies serialize" do
    with_temp_store do |store, _, _|
      done = Channel(Nil).new
      20.times do |i|
        spawn do
          store.modify("p") do |current|
            base = current.as(LLM::AI::OAuthCredential?) || oauth("r", "a", 0_i64)
            ids  = base.extra["ids"]?.try(&.as_a) || [] of JSON::Any
            ids  = ids + [JSON::Any.new(i)]
            oauth("r", "a", 0_i64, base.extra.merge({"ids" => JSON::Any.new(ids)}))
          end
          done.send nil
        end
      end
      20.times { done.receive }
      final = store.read("p").as(LLM::AI::OAuthCredential)
      final.extra["ids"].as_a.size.should eq 20
    end
  end

  it "treats corrupt file as empty" do
    with_temp_store do |store, path, _|
      File.write(path, "not json")
      store.read("p").should be_nil
      store.modify("p") { LLM::AI::ApiKeyCredential.new("k") }
      store.read("p").should eq LLM::AI::ApiKeyCredential.new("k")
    end
  end

  it "writes files with restricted permissions" do
    with_temp_store do |_store, _path, dir|
      nested = LLM::AI::FileCredentialStore.new(Path[dir, "sub", "auth.json"])
      nested.modify("p") { LLM::AI::ApiKeyCredential.new("k") }
      (File.info(Path[dir, "sub", "auth.json"]).permissions.value & 0o777).should eq 0o600
      (File.info(Path[dir, "sub"]).permissions.value & 0o777).should eq 0o700
    end
  end

  it "uses the default config path when none given" do
    LLM::AI::FileCredentialStore.new.path.should eq(Path.home / ".config/pi-ai-cr/auth.json")
  end
end
