# src/pi_ai/http.cr
require "http/client"

module LLM::AI
  module Http
    RETRYABLE_STATUSES      = [408, 409, 429]
    MAX_RETRY_DELAY_SECONDS = 60

    class Error < Exception
      getter status : Int32
      getter headers : HTTP::Headers
      getter body : String

      def initialize(@status, message : String, @headers, @body)
        super(message)
      end
    end

    struct Options
      getter connect_timeout : Time::Span
      getter read_timeout : Time::Span
      getter max_retries : Int32

      def initialize(@connect_timeout : Time::Span = 10.seconds, @read_timeout : Time::Span = 10.minutes, @max_retries : Int32 = 0)
      end
    end

    def self.request(url : String, method : String, headers : Hash(String, String)?, body : String?, options : Options, abort : AbortHandle? = nil, &on_response : HTTP::Client::Response -> Nil) : Nil
      retries = 0
      loop do
        error = perform_once(url, method, headers, body, options, abort, on_response)
        return if error.nil?
        raise AbortError.new("Request was aborted") if abort.try(&.aborted?)
        if retryable?(error) && retries < options.max_retries
          delay = retry_delay(error, retries)
          abortable_sleep(delay, abort)
          retries += 1
          next
        end
        raise error
      end
    end

    private def self.perform_once(url, method, headers, body, options, abort, on_response) : Error?
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = options.connect_timeout
      client.read_timeout = options.read_timeout
      done = Channel(Nil).new
      if abort
        spawn do
          loop do
            if abort.aborted?
              client.close rescue nil
              break
            end
            break if done.closed?
            sleep 10.milliseconds
          end
        end
      end
      captured = nil
      begin
        client.exec(method, uri.request_target, headers: build_headers(headers), body: body) do |response|
          if response.success?
            on_response.call(response)
          else
            body_text = response.body_io.gets_to_end
            captured = Error.new(response.status_code, error_message(response, body_text), response.headers, body_text)
          end
        end
      rescue ex
        captured = Error.new(0, ex.message || "request failed", HTTP::Headers.new, "")
      ensure
        done.close
        client.close rescue nil
      end
      captured
    end

    private def self.build_headers(headers : Hash(String, String)?) : HTTP::Headers
      http_headers = HTTP::Headers.new
      headers.try &.each { |key, value| http_headers[key] = value }
      http_headers
    end

    private def self.error_message(response, body : String) : String
      snippet = body.size > 4000 ? body[0, 4000] : body
      "HTTP #{response.status_code} #{response.status_message}: #{snippet}"
    end

    private def self.retryable?(error : Error) : Bool
      should_retry = error.headers["x-should-retry"]?
      return true if should_retry == "true"
      return false if should_retry == "false"
      return true if error.status == 0
      error.status >= 500 || RETRYABLE_STATUSES.includes?(error.status)
    end

    private def self.retry_delay(error : Error, attempt : Int32) : Time::Span
      if (ms = error.headers["retry-after-ms"]?)
        begin
          value = ms.to_f
          if value > MAX_RETRY_DELAY_SECONDS * 1000
            raise Error.new(error.status, "retry-after-ms #{ms}ms exceeds maximum retry delay of #{MAX_RETRY_DELAY_SECONDS}s", error.headers, error.body)
          end
          return value.milliseconds if value.finite?
        rescue ArgumentError
        end
      end
      if (secs = error.headers["retry-after"]?)
        value = retry_after_seconds(secs)
        if value
          if value > MAX_RETRY_DELAY_SECONDS
            raise Error.new(error.status, "retry-after #{secs}s exceeds maximum retry delay of #{MAX_RETRY_DELAY_SECONDS}s", error.headers, error.body)
          end
          return value.seconds
        end
      end
      base = Math.min(0.5 * (2 ** attempt), 8.0)
      (base * (0.75 + rand * 0.25)).seconds
    end

    private def self.retry_after_seconds(raw : String) : Float64?
      begin
        return raw.to_f
      rescue ArgumentError
      end
      begin
        target = Time::Format::RFC_2822.parse(raw)
        return Math.max(0.0, (target - Time.utc).total_seconds)
      rescue Time::Format::Error
      end
      nil
    end

    private def self.abortable_sleep(delay : Time::Span, abort : AbortHandle?) : Nil
      if abort.nil?
        sleep delay
        return
      end
      deadline = Time.instant + delay
      while Time.instant < deadline
        raise AbortError.new("Request was aborted") if abort.aborted?
        sleep [100.milliseconds, deadline - Time.instant].min
      end
    end
  end
end
