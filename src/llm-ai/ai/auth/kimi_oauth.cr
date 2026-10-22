# src/llm/ai/auth/kimi_oauth.cr
require "uri"
require "../http"

module LLM::AI::Auth
  module Kimi
    CLIENT_ID         = "17e5f671-d194-4dfb-9706-5516cb48c098"
    DEFAULT_HOST      = "https://auth.kimi.com"
    DEVICE_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code"

    private enum PollStatus
      Pending
      SlowDown
      Denied
      Expired
      Success
    end

    private struct PollResult
      getter status : PollStatus
      getter credential : OAuthCredential?

      def initialize(@status : PollStatus, @credential : OAuthCredential? = nil)
      end
    end

    private struct DeviceAuthorization
      getter device_code : String
      getter user_code : String
      getter verification_uri : String
      getter verification_uri_complete : String
      getter interval : Int32?
      getter expires_in : Int32?

      def initialize(@device_code, @user_code, @verification_uri, @verification_uri_complete, @interval, @expires_in)
      end
    end

    def self.login(interaction : Interaction, client_id : String = CLIENT_ID, auth_host : String? = nil,
                   *, interval_seconds : Int32 = 5, slow_down_seconds : Int32 = 5, wait_before_first_poll : Bool = true) : OAuthCredential
      host = resolve_host(auth_host)
      device = request_device_authorization(host, client_id)
      interval = Math.max(device.interval || interval_seconds, 1)
      interaction.notify(DeviceCode.new(
        device.user_code,
        device.verification_uri_complete.empty? ? device.verification_uri : device.verification_uri_complete,
        interval,
        device.expires_in || 900,
      ))
      sleep interval.seconds if wait_before_first_poll
      deadline = Time.instant + (device.expires_in || 900).seconds
      loop do
        if Time.instant >= deadline
          raise Error.new("Device authorization expired, restart login")
        end
        result = poll_token(host, client_id, device.device_code)
        case result.status
        when PollStatus::Pending
          sleep interval.seconds
        when PollStatus::SlowDown
          interval += slow_down_seconds
          sleep interval.seconds
        when PollStatus::Denied
          raise Error.new("Device authorization denied")
        when PollStatus::Expired
          raise Error.new("Device authorization expired, restart login")
        when PollStatus::Success
          return result.credential.not_nil!
        end
      end
    end

    def self.refresh(refresh_token : String, auth_host : String? = nil) : OAuthCredential
      host = resolve_host(auth_host)
      body = HTTP::Params.encode({
        "client_id"     => CLIENT_ID,
        "grant_type"    => "refresh_token",
        "refresh_token" => refresh_token,
      })
      attempts = 0
      loop do
        attempts += 1
        begin
          return post_token(host, body)
        rescue ex : Http::Error
          raise DeadCredential.new("Kimi refresh token rejected: #{ex.message}") if ex.status == 401 || ex.status == 403 || ex.body.includes?("invalid_grant")
          raise ex if attempts >= 3 || !retryable?(ex.status)
          sleep (1000 * (2 ** (attempts - 1))).milliseconds
        end
      end
    end

    private def self.resolve_host(auth_host : String?) : String
      auth_host || ENV["KIMI_CODE_OAUTH_HOST"]? || ENV["KIMI_OAUTH_HOST"]? || DEFAULT_HOST
    end

    private def self.retryable?(status : Int32) : Bool
      status == 429 || status >= 500
    end

    private def self.request_device_authorization(host : String, client_id : String) : DeviceAuthorization
      body = HTTP::Params.encode({"client_id" => client_id})
      response_body = post_form(host, "/api/oauth/device_authorization", body)
      json = JSON.parse(response_body)
      DeviceAuthorization.new(
        json["device_code"].as_s,
        json["user_code"].as_s,
        json["verification_uri"].as_s,
        json["verification_uri_complete"]?.try(&.as_s) || "",
        json["interval"]?.try(&.as_i),
        json["expires_in"]?.try(&.as_i),
      )
    end

    private def self.poll_token(host : String, client_id : String, device_code : String) : PollResult
      body = HTTP::Params.encode({
        "client_id"   => client_id,
        "device_code" => device_code,
        "grant_type"  => DEVICE_GRANT_TYPE,
      })
      response_body = begin
        post_form(host, "/api/oauth/token", body)
      rescue ex : Http::Error
        return parse_poll_error(ex)
      end
      json = JSON.parse(response_body)
      access = json["access_token"]?.try(&.as_s)
      refresh = json["refresh_token"]?.try(&.as_s)
      expires_in = json["expires_in"]?.try(&.as_i)
      if access.nil? || refresh.nil? || expires_in.nil?
        raise Error.new("Kimi token response missing fields")
      end
      PollResult.new(PollStatus::Success, OAuthCredential.new(refresh, access, Time.utc.to_unix_ms + expires_in.to_i64 * 1000))
    end

    private def self.parse_poll_error(http_error : Http::Error) : PollResult
      error = begin
        JSON.parse(http_error.body)["error"]?.try(&.as_s)
      rescue JSON::ParseException
        nil
      end
      case error
      when "authorization_pending"
        PollResult.new(PollStatus::Pending)
      when "slow_down"
        PollResult.new(PollStatus::SlowDown)
      when "expired_token"
        PollResult.new(PollStatus::Expired)
      when "access_denied"
        PollResult.new(PollStatus::Denied)
      else
        raise Error.new("Kimi device authorization failed: #{error || http_error.message}")
      end
    end

    private def self.post_token(host : String, body : String) : OAuthCredential
      response_body = post_form(host, "/api/oauth/token", body)
      json = JSON.parse(response_body)
      access = json["access_token"]?.try(&.as_s)
      refresh = json["refresh_token"]?.try(&.as_s)
      expires_in = json["expires_in"]?.try(&.as_i)
      if access.nil? || refresh.nil? || expires_in.nil?
        raise Error.new("Kimi token response missing fields")
      end
      OAuthCredential.new(refresh, access, Time.utc.to_unix_ms + expires_in.to_i64 * 1000)
    end

    private def self.post_form(host : String, path : String, body : String) : String
      response_body = ""
      Http.request(
        "#{host}#{path}",
        "POST",
        {"Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/json"},
        body,
        Http::Options.new(read_timeout: 30.seconds),
        nil,
      ) { |response| response_body = response.body_io.gets_to_end }
      response_body
    end
  end
end
