# src/llm-ai/auth/oauth.cr
require "base64"
require "digest/sha256"
require "http/server"
require "random/secure"

module LLM::AI::Auth
  class Error < Exception
  end

  class DeadCredential < Error
  end

  enum PromptKind
    Select
    Secret
    ManualCode
  end

  abstract class Interaction
    abstract def prompt(kind : PromptKind, message : String) : String
    abstract def notify(event : AuthEvent) : Nil
  end

  class CLIInteraction < Interaction
    def initialize(@stdin : IO = STDIN, @stdout : IO = STDOUT)
    end

    def prompt(kind : PromptKind, message : String) : String
      @stdout.puts message
      line = if kind.secret?
               if fd = @stdin.as?(IO::FileDescriptor)
                 fd.noecho { @stdin.gets }
               else
                 @stdin.gets
               end
             else
               @stdin.gets
             end
      (line || "").strip
    end

    def notify(event : AuthEvent) : Nil
      case event
      in Info
        @stdout.puts event.text
      in AuthUrl
        @stdout.puts event.instructions
        @stdout.puts event.url
      in DeviceCode
        @stdout.puts "Code: #{event.user_code}"
        @stdout.puts "Visit: #{event.verification_uri}"
      in Progress
        @stdout.puts event.text
      end
    end
  end

  abstract class AuthEvent
  end

  class Info < AuthEvent
    getter text : String

    def initialize(@text : String)
    end
  end

  class AuthUrl < AuthEvent
    getter url : String
    getter instructions : String

    def initialize(@url : String, @instructions : String)
    end
  end

  class DeviceCode < AuthEvent
    getter user_code : String
    getter verification_uri : String
    getter interval_seconds : Int32
    getter expires_in_seconds : Int32

    def initialize(@user_code : String, @verification_uri : String, @interval_seconds : Int32, @expires_in_seconds : Int32)
    end
  end

  class Progress < AuthEvent
    getter text : String

    def initialize(@text : String)
    end
  end

  module PKCE
    def self.generate : {String, String}
      verifier = Base64.urlsafe_encode(Random::Secure.random_bytes(32), padding: false)
      challenge = Base64.urlsafe_encode(Digest::SHA256.digest(verifier), padding: false)
      {verifier, challenge}
    end
  end

  class OAuthCallbackServer
    getter redirect_uri : String

    @server : HTTP::Server
    @tcp : TCPServer
    @claimed : Bool
    @code_channel : Channel(String)
    @failure_channel : Channel(String)
    @listening : Bool

    def initialize(@host : String, @path : String, @expected_state : String, @complete : String -> String?)
      @claimed = false
      @code_channel = Channel(String).new(1)
      @failure_channel = Channel(String).new(1)
      @server = HTTP::Server.new { |context| handle(context) }
      @tcp = begin
        TCPServer.new(@host, 53692)
      rescue Socket::BindError
        TCPServer.new(@host, 0)
      end
      @server.bind(@tcp)
      @listening = false
      @redirect_uri = "http://#{@host}:#{port}#{@path}"
    end

    def port : Int32
      @tcp.local_address.as(Socket::IPAddress).port
    end

    def start : Nil
      unless @listening
        @listening = true
        spawn { @server.listen }
      end
    end

    def wait : String
      select
      when code = @code_channel.receive
        raise Error.new("Login cancelled") if code.empty?
        code
      when message = @failure_channel.receive
        raise Error.new(message)
      end
    end

    def cancel : Nil
      @code_channel.send("") unless @code_channel.closed?
    end

    private def handle(context : HTTP::Server::Context) : Nil
      request = context.request
      response = context.response
      response.content_type = "text/html; charset=utf-8"
      if request.method != "GET" || request.path != @path
        response.status_code = 404
        return
      end
      if @claimed
        response.status_code = 409
        return
      end
      params = request.query_params
      if error = params["error"]?
        @failure_channel.send("OAuth authorization failed: #{error}")
        response.status_code = 400
        return
      end
      if params["state"]? != @expected_state
        @failure_channel.send("OAuth state mismatch")
        response.status_code = 400
        return
      end
      code = params["code"]?
      if code.nil? || code.empty?
        @failure_channel.send("Missing authorization code")
        response.status_code = 400
        return
      end
      @claimed = true
      if error_message = @complete.call(code)
        @failure_channel.send(error_message)
        response.status_code = 502
        return
      end
      @code_channel.send(code)
      response.status_code = 200
      response.print "<html><body>Login successful. You may close this window.</body></html>"
    end
  end
end
