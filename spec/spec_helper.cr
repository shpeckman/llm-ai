# spec/spec_helper.cr
require "spec"
require "file_utils"
require "http/client"
require "http/server"
require "../src/llm-ai"

class RecordingInteraction < LLM::AI::Auth::Interaction
  getter events      : Array(LLM::AI::Auth::AuthEvent)
  getter event_times : Array(Time::Instant)
  getter auth_urls   : Array(LLM::AI::Auth::AuthUrl)

  @prompt_results : Array(String)
  @prompt_index   : Int32

  def initialize(@prompt_results : Array(String))
    @events       = [] of LLM::AI::Auth::AuthEvent
    @event_times  = [] of Time::Instant
    @auth_urls    = [] of LLM::AI::Auth::AuthUrl
    @prompt_index = 0
  end

  def prompt(kind : LLM::AI::Auth::PromptKind, message : String) : String
    result = @prompt_results[@prompt_index]? || ""
    @prompt_index += 1
    result
  end

  def notify(event : LLM::AI::Auth::AuthEvent) : Nil
    @events << event
    @event_times << Time.instant
    if url_event = event.as?(LLM::AI::Auth::AuthUrl)
      @auth_urls << url_event
    end
  end
end

class MockApi
  getter requests     : Array(Tuple(String, String, String))
  getter last_headers : HTTP::Headers?
  getter port         : Int32

  @body         : String
  @status       : Int32
  @content_type : String
  @headers      : Hash(String, String)
  @server       : HTTP::Server
  @started      : Bool
  @closed       : Bool

  def initialize
    @requests     = [] of Tuple(String, String, String)
    @last_headers = nil
    @body         = ""
    @status       = 200
    @content_type = "text/event-stream"
    @headers      = {} of String => String
    @started      = false
    @closed       = false
    @server = HTTP::Server.new do |context|
      request = context.request
      @requests << {request.method, request.resource, request.body.try(&.gets_to_end) || ""}
      @last_headers = request.headers.dup
      response      = context.response
      response.status_code = @status
      response.content_type = @content_type
      @headers.each { |key, value| response.headers[key] = value }
      response.print @body
    end
    @port = @server.bind_unused_port.port
  end

  def serve(body : String, status : Int32 = 200, content_type : String = "text/event-stream", headers : Hash(String, String) = {} of String => String) : MockApi
    @body         = body
    @status       = status
    @content_type = content_type
    @headers      = headers
    self
  end

  def start : MockApi
    unless @started || @closed
      @started = true
      spawn do
        @server.listen
      rescue ex
        raise ex unless @closed
      end
    end
    self
  end

  def close
    return if @closed
    @closed = true
    @server.close
  end
end

def with_env(env : Hash(String, String), &)
  previous = {} of String => String?
  env.each_key { |key| previous[key] = ENV[key]? }
  begin
    env.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      if value
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
  end
end

def with_temp_store(&)
  dir = File.tempname("pi-ai-cr-spec-")
  Dir.mkdir_p(dir)
  store = LLM::AI::FileCredentialStore.new(Path[dir, "auth.json"])
  begin
    yield store, Path[dir, "auth.json"], dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

class ScriptedApi
  getter requests    : Int32
  getter request_log : Array(Tuple(String, String, String, Time::Instant))
  getter port        : Int32

  @responses : Array(Tuple(Int32, Hash(String, String), String))
  @server    : HTTP::Server
  @started   : Bool
  @closed    : Bool

  def initialize(@responses)
    @requests    = 0
    @request_log = [] of Tuple(String, String, String, Time::Instant)
    @started     = false
    @closed      = false
    @server = HTTP::Server.new do |context|
      request = context.request
      @request_log << {request.method, request.resource, request.body.try(&.gets_to_end) || "", Time.instant}
      status, headers, body = next_response
      response = context.response
      response.status_code = status
      headers.each { |key, value| response.headers[key] = value }
      response.print body
    end
    @port = @server.bind_unused_port.port
  end

  private def next_response
    idx = @requests
    @requests += 1
    @responses[Math.min(idx, @responses.size - 1)]
  end

  def start : ScriptedApi
    unless @started || @closed
      @started = true
      spawn do
        @server.listen
      rescue ex
        raise ex unless @closed
      end
    end
    self
  end

  def close
    return if @closed
    @closed = true
    @server.close
  end
end
