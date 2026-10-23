# spec/rest_client_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def rest_provider(base_url : String, id : String = "moonshot") : LLM::AI::Provider
  model = LLM::AI::Model.new("kimi-k3", "Kimi K3", id, base_url, LLM::AI::ApiKind::OpenaiCompletions,
    [LLM::AI::InputKind::Text], 256_000, 8192, true,
    LLM::AI::ModelCost.new(1.2, 4.0, 0.15, 1.2, nil))
  LLM::AI::Provider.new(id, "Moonshot", base_url, {} of String => String,
    LLM::AI::Auth::ProviderAuth.new(LLM::AI::Auth::ApiKeyAuth.new("Moonshot API key", ["MOONSHOT_API_KEY"])),
    [model],
    ->(stream_model : LLM::AI::Model, context : LLM::AI::Context, options : LLM::AI::StreamOptions, auth : LLM::AI::Auth::AuthResult, abort : LLM::AI::AbortHandle?) {
      LLM::AI::Api::OpenAICompletions.stream(stream_model, context, options, auth, abort)
    })
end

private def rest_client(base_url : String, id : String = "moonshot") : LLM::AI::Rest::Client
  auth = LLM::AI::Auth::AuthResult.new(LLM::AI::Auth::ModelAuth.new("test-key"), "ambient env")
  LLM::AI::Rest::Client.new(rest_provider(base_url, id), auth)
end

private def json_response(body : String) : MockApi
  MockApi.new.serve(body, content_type: "application/json").start
end

describe LLM::AI::Rest::Client do
  it "lists models" do
    api = json_response(%({"object":"list","data":[{"id":"kimi-k3","object":"model","created":1,"owned_by":"moonshot","context_length":262144,"supports_image_in":true,"supports_reasoning":true}]}))
    begin
      models = rest_client("http://127.0.0.1:#{api.port}").list_models
      models.size.should eq 1
      models[0].id.should eq "kimi-k3"
      models[0].context_length.should eq 262144
      models[0].supports_reasoning.should be_true
      api.requests[0][0].should eq "GET"
      api.requests[0][1].should eq "/v1/models"
      api.last_headers.not_nil!["Authorization"].should eq "Bearer test-key"
    ensure
      api.close
    end
  end

  it "fetches balance" do
    api = json_response(%({"code":0,"data":{"available_balance":49.5,"voucher_balance":46.5,"cash_balance":3.0},"scode":"0x0","status":true}))
    begin
      balance = rest_client("http://127.0.0.1:#{api.port}").balance
      balance.status.should be_true
      balance.data.available_balance.should eq 49.5
      api.requests[0][1].should eq "/v1/users/me/balance"
    ensure
      api.close
    end
  end

  it "uploads a file as multipart form data" do
    api = json_response(%({"id":"f1","object":"file","bytes":5,"created_at":10,"filename":"a.txt","purpose":"batch","status":"uploaded"}))
    path = File.tempname("rest-upload", ".txt")
    File.write(path, "hello")
    begin
      file = rest_client("http://127.0.0.1:#{api.port}").upload_file(path, "batch")
      file.id.should eq "f1"
      api.requests[0][0].should eq "POST"
      api.requests[0][1].should eq "/v1/files"
      api.last_headers.not_nil!["Content-Type"].should start_with "multipart/form-data"
      api.requests[0][2].should contain "hello"
      api.requests[0][2].should contain "batch"
    ensure
      api.close
      File.delete(path) if File.exists?(path)
    end
  end

  it "gets, lists, deletes files and reads content" do
    api = MockApi.new.serve(%({"id":"f1","object":"file","bytes":5,"created_at":10,"filename":"a.txt","purpose":"batch","status":"uploaded"}), content_type: "application/json").start
    begin
      client = rest_client("http://127.0.0.1:#{api.port}")
      client.get_file("f1").filename.should eq "a.txt"
      api.requests[0][1].should eq "/v1/files/f1"

      api.serve(%({"object":"list","data":[]}), content_type: "application/json")
      client.list_files.should be_empty
      api.requests[1][1].should eq "/v1/files"

      api.serve(%({"id":"f1","object":"file","deleted":true}), content_type: "application/json")
      client.delete_file("f1").deleted.should be_true
      api.requests[2][0].should eq "DELETE"
      api.requests[2][1].should eq "/v1/files/f1"

      api.serve("file body", content_type: "text/plain")
      client.file_content("f1").should eq "file body"
      api.requests[3][1].should eq "/v1/files/f1/content"
    ensure
      api.close
    end
  end

  it "estimates tokens from a context" do
    api = json_response(%({"data":{"total_tokens":80}}))
    begin
      model = rest_provider("http://127.0.0.1:#{api.port}").models.first
      context = LLM::AI::Context.new(
        [LLM::AI::UserMessage.new("hello", Time.utc)] of LLM::AI::Message,
        system_prompt: "be nice")
      estimate = rest_client("http://127.0.0.1:#{api.port}").estimate_tokens(model, context)
      estimate.total_tokens.should eq 80
      api.requests[0][1].should eq "/v1/tokenizers/estimate-token-count"
      payload = JSON.parse(api.requests[0][2])
      payload["model"].should eq "kimi-k3"
      payload["messages"][0].should eq JSON.parse(%({"role":"system","content":"be nice"}))
      payload["messages"][1].should eq JSON.parse(%({"role":"user","content":"hello"}))
    ensure
      api.close
    end
  end

  it "verifies a signature" do
    api = json_response(%({"valid":true}))
    begin
      result = rest_client("http://127.0.0.1:#{api.port}").verify_signature("n1", 1786338000123_i64, "kimi-k3", "reqsigv1_x")
      result.valid.should be_true
      payload = JSON.parse(api.requests[0][2])
      payload["nonce"].should eq "n1"
      payload["timestamp"].should eq 1786338000123_i64
      api.requests[0][1].should eq "/v1/signatures/verify"
    ensure
      api.close
    end
  end

  it "runs web search and pro search" do
    api = MockApi.new.serve(%({"search_results":[{"authority":"high","date":"2026-01-01","icon":"i","mime":"text/html","site_name":"s","snippet":"sn","text":"t","title":"ti","url":"u"}]}), content_type: "application/json").start
    begin
      client = rest_client("http://127.0.0.1:#{api.port}")
      results = client.web_search("crystal lang", limit: 3, include_content: true)
      results[0].title.should eq "ti"
      api.requests[0][1].should eq "/v1/tools/search"
      payload = JSON.parse(api.requests[0][2])
      payload["text_query"].should eq "crystal lang"
      payload["limit"].should eq 3
      payload["include_content"].should be_true

      api.serve(%({"search_results":[{"authority":"high","date":"d","icon":"i","mime":"m","site_name":"s","snippet":"sn","title":"t","url":"u","chunks":[{"text":"c","score":0.9}]}]}), content_type: "application/json")
      pro = client.web_search_pro("crystal", sites: ["crystal-lang.org"], time_window: {"2026-01-01", nil})
      pro[0].chunks[0].score.should eq 0.9
      api.requests[1][1].should eq "/v1/tools/search_pro"
      payload = JSON.parse(api.requests[1][2])
      payload["sites"][0].should eq "crystal-lang.org"
      payload["time_window"]["start"].should eq "2026-01-01"
      payload["time_window"].as_h.has_key?("end").should be_false
    ensure
      api.close
    end
  end

  it "fetches a url" do
    api = json_response(%({"url":"https://x","markdown":"# hi","title":"t"}))
    begin
      result = rest_client("http://127.0.0.1:#{api.port}").fetch("https://x")
      result.markdown.should eq "# hi"
      api.requests[0][1].should eq "/v1/tools/fetch"
    ensure
      api.close
    end
  end

  it "manages batches" do
    batch_json = %({"id":"b1","object":"batch","endpoint":"/v1/chat/completions","input_file_id":"f1","completion_window":"12h","status":"validating","output_file_id":null,"error_file_id":null,"created_at":1,"in_progress_at":null,"expires_at":null,"finalizing_at":null,"completed_at":null,"failed_at":null,"cancelling_at":null,"cancelled_at":null,"request_counts":{"completed":0,"failed":0,"total":2},"metadata":null})
    api = MockApi.new.serve(batch_json, content_type: "application/json").start
    begin
      client = rest_client("http://127.0.0.1:#{api.port}")
      batch = client.create_batch("f1", "12h")
      batch.id.should eq "b1"
      batch.request_counts.total.should eq 2
      payload = JSON.parse(api.requests[0][2])
      payload["endpoint"].should eq "/v1/chat/completions"

      api.serve(%({"object":"list","data":[#{batch_json}],"has_more":false}), content_type: "application/json")
      list = client.list_batches(after: "b0", limit: 10)
      list.data.size.should eq 1
      api.requests[1][1].should eq "/v1/batches?after=b0&limit=10"

      api.serve(batch_json, content_type: "application/json")
      client.get_batch("b1").status.should eq "validating"
      api.requests[2][1].should eq "/v1/batches/b1"

      client.cancel_batch("b1").id.should eq "b1"
      api.requests[3][0].should eq "POST"
      api.requests[3][1].should eq "/v1/batches/b1/cancel"
    ensure
      api.close
    end
  end

  it "raises capability errors for unsupported providers" do
    client = rest_client("http://127.0.0.1:1", id: "deepseek")
    expect_raises(LLM::AI::ModelsError, /no REST endpoints/) do
      client.balance
    end
  end

  it "surfaces http errors" do
    api = MockApi.new.serve(%({"error":{"message":"nope"}}), status: 401, content_type: "application/json").start
    begin
      expect_raises(LLM::AI::Http::Error, /401/) do
        rest_client("http://127.0.0.1:#{api.port}").balance
      end
    ensure
      api.close
    end
  end
end
