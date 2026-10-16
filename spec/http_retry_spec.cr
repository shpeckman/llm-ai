# spec/http_retry_spec.cr
require "./spec_helper"
require "../src/llm-ai"

describe LLM::AI::Http do
  it "returns the response on 200" do
    api = ScriptedApi.new([{200, {} of String => String, "ok"}]).start
    begin
      captured = ""
      LLM::AI::Http.request(
        "http://127.0.0.1:#{api.port}/v1/test", "POST",
        nil, "{}", LLM::AI::Http::Options.new
      ) { |response| captured = response.body_io.gets_to_end }
      captured.should eq "ok"
      api.requests.should eq 1
    ensure
      api.close
    end
  end

  it "honors retry-after-ms" do
    api = ScriptedApi.new([
      {429, {"retry-after-ms" => "10"}, "busy"},
      {429, {"retry-after-ms" => "10"}, "busy"},
      {200, {} of String => String, "ok"},
    ]).start
    begin
      captured = ""
      LLM::AI::Http.request(
        "http://127.0.0.1:#{api.port}/v1/test", "POST",
        nil, "{}", LLM::AI::Http::Options.new(max_retries: 2)
      ) { |response| captured = response.body_io.gets_to_end }
      captured.should eq "ok"
      api.requests.should eq 3
    ensure
      api.close
    end
  end

  it "fails immediately when retry-after exceeds 60s" do
    api = ScriptedApi.new([{429, {"retry-after" => "120"}, "slow down"}]).start
    begin
      error = expect_raises(LLM::AI::Http::Error) do
        LLM::AI::Http.request(
          "http://127.0.0.1:#{api.port}/v1/test", "POST",
          nil, "{}", LLM::AI::Http::Options.new(max_retries: 2)
        ) { }
      end
      (error.message || "").should contain "120"
      api.requests.should eq 1
    ensure
      api.close
    end
  end

  it "backs off exponentially" do
    api = ScriptedApi.new(Array.new(4) { {500, {} of String => String, "boom"} }).start
    begin
      start = Time.instant
      expect_raises(LLM::AI::Http::Error) do
        LLM::AI::Http.request(
          "http://127.0.0.1:#{api.port}/v1/test", "POST",
          nil, "{}", LLM::AI::Http::Options.new(max_retries: 3)
        ) { }
      end
      elapsed = Time.instant - start
      elapsed.total_seconds.should be >= 2.5
      api.requests.should eq 4
    ensure
      api.close
    end
  end

  it "aborts during backoff" do
    api = ScriptedApi.new([{429, {} of String => String, "busy"}]).start
    begin
      abort = LLM::AI::AbortHandle.new
      spawn do
        sleep 100.milliseconds
        abort.abort
      end
      elapsed = Time.measure do
        expect_raises(LLM::AI::AbortError) do
          LLM::AI::Http.request(
            "http://127.0.0.1:#{api.port}/v1/test", "POST",
            nil, "{}", LLM::AI::Http::Options.new(max_retries: 5), abort
          ) { }
        end
      end
      elapsed.total_seconds.should be < 2
      api.requests.should eq 1
    ensure
      api.close
    end
  end

  it "retries network errors and raises with status 0 after max_retries" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close
    elapsed = Time.measure do
      error = expect_raises(LLM::AI::Http::Error) do
        LLM::AI::Http.request(
          "http://127.0.0.1:#{port}/v1/test", "POST",
          nil, "{}", LLM::AI::Http::Options.new(max_retries: 1)
        ) { }
      end
      error.status.should eq 0
    end
    elapsed.total_seconds.should be >= 0.3
  end

  it "aborts during a network error without retrying" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    accepts = Channel(Int32).new
    spawn do
      count = 0
      while socket = server.accept?
        count += 1
        socket.read_timeout = 2.seconds
        socket.gets
        socket.close rescue nil
      end
      accepts.send(count)
    end
    abort = LLM::AI::AbortHandle.new
    spawn do
      sleep 100.milliseconds
      abort.abort
    end
    elapsed = Time.measure do
      expect_raises(LLM::AI::AbortError) do
        LLM::AI::Http.request(
          "http://127.0.0.1:#{port}/v1/test", "POST",
          nil, "{}", LLM::AI::Http::Options.new(max_retries: 3), abort
        ) { }
      end
    end
    elapsed.total_seconds.should be < 2
    server.close
    accepts.receive.should eq 1
  end

  it "fails immediately when retry-after-ms exceeds 60s" do
    api = ScriptedApi.new([{429, {"retry-after-ms" => "60001"}, "slow down"}]).start
    begin
      error = expect_raises(LLM::AI::Http::Error) do
        LLM::AI::Http.request(
          "http://127.0.0.1:#{api.port}/v1/test", "POST",
          nil, "{}", LLM::AI::Http::Options.new(max_retries: 2)
        ) { }
      end
      (error.message || "").should contain "60001"
      (error.message || "").should contain "exceeds maximum retry delay"
      api.requests.should eq 1
    ensure
      api.close
    end
  end

  it "honors fractional retry-after seconds" do
    api = ScriptedApi.new([
      {429, {"retry-after" => "1.5"}, "busy"},
      {200, {} of String => String, "ok"},
    ]).start
    begin
      captured = ""
      LLM::AI::Http.request(
        "http://127.0.0.1:#{api.port}/v1/test", "POST",
        nil, "{}", LLM::AI::Http::Options.new(max_retries: 1)
      ) { |response| captured = response.body_io.gets_to_end }
      captured.should eq "ok"
      api.requests.should eq 2
      delay = api.request_log[1][3] - api.request_log[0][3]
      delay.total_seconds.should be >= 1.4
    ensure
      api.close
    end
  end

  it "honors retry-after as an HTTP date" do
    future = (Time.utc + 2.seconds).to_rfc2822
    api = ScriptedApi.new([
      {429, {"retry-after" => future}, "busy"},
      {200, {} of String => String, "ok"},
    ]).start
    begin
      captured = ""
      LLM::AI::Http.request(
        "http://127.0.0.1:#{api.port}/v1/test", "POST",
        nil, "{}", LLM::AI::Http::Options.new(max_retries: 1)
      ) { |response| captured = response.body_io.gets_to_end }
      captured.should eq "ok"
      api.requests.should eq 2
      delay = api.request_log[1][3] - api.request_log[0][3]
      delay.total_seconds.should be >= 0.9
    ensure
      api.close
    end
  end

  it "retries when x-should-retry is true regardless of status" do
    api = ScriptedApi.new([
      {400, {"x-should-retry" => "true"}, "bad request"},
      {200, {} of String => String, "ok"},
    ]).start
    begin
      captured = ""
      LLM::AI::Http.request(
        "http://127.0.0.1:#{api.port}/v1/test", "POST",
        nil, "{}", LLM::AI::Http::Options.new(max_retries: 1)
      ) { |response| captured = response.body_io.gets_to_end }
      captured.should eq "ok"
      api.requests.should eq 2
    ensure
      api.close
    end
  end
end
