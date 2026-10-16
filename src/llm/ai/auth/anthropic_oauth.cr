# src/pi_ai/auth/anthropic_oauth.cr
require "uri"
require "../http"

module LLM::AI
  module Auth
    struct AuthHosts
      getter authorize_url : String
      getter token_url : String

      def initialize(@authorize_url : String = "https://claude.ai/oauth/authorize", @token_url : String = "https://platform.claude.com/v1/oauth/token")
      end
    end

    module Anthropic
      CLIENT_ID          = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
      SCOPES             = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
      CALLBACK_PATH      = "/callback"
      COPY_CODE_REDIRECT = "https://platform.claude.com/oauth/code/callback"
      EXPIRY_MARGIN_MS   = 300_000_i64

      def self.login(interaction : Interaction, no_browser : Bool = false, hosts : AuthHosts? = nil) : OAuthCredential
        hosts = hosts || AuthHosts.new
        verifier, challenge = PKCE.generate
        if no_browser
          url = build_authorize_url(hosts.authorize_url, challenge, verifier, COPY_CODE_REDIRECT)
          interaction.notify(AuthUrl.new(url, "Visit the URL, sign in, and paste the code shown on the page."))
          input = interaction.prompt(:manual_code, "Paste the authorization code:")
          exchange_manual(hosts.token_url, input, verifier, COPY_CODE_REDIRECT)
        else
          host = ENV["PI_OAUTH_CALLBACK_HOST"]? || "127.0.0.1"
          server = OAuthCallbackServer.new(host, CALLBACK_PATH, verifier, ->(code : String) : String? { nil })
          server.start
          begin
            url = build_authorize_url(hosts.authorize_url, challenge, verifier, server.redirect_uri)
            interaction.notify(AuthUrl.new(url, "Complete login in your browser. If the browser is on another machine, paste the final redirect URL here."))
            exchange_manual(hosts.token_url, wait_code(server, interaction), verifier, server.redirect_uri)
          ensure
            server.cancel
          end
        end
      end

      def self.refresh(refresh_token : String, hosts : AuthHosts? = nil) : OAuthCredential
        hosts = hosts || AuthHosts.new
        body = {"grant_type" => "refresh_token", "client_id" => CLIENT_ID, "refresh_token" => refresh_token}.to_json
        post_token(hosts.token_url, body)
      rescue ex : Http::Error
        if ex.status == 400 || ex.status == 401 || ex.status == 403 || ex.body.includes?("invalid_grant")
          raise DeadCredential.new("Anthropic refresh token rejected: #{ex.message}")
        end
        raise Error.new("OAuth refresh failed: #{ex.message}")
      end

      private def self.build_authorize_url(authorize : String, challenge : String, verifier : String, redirect : String) : String
        params = HTTP::Params.encode({
          "code"                  => "true",
          "client_id"             => CLIENT_ID,
          "response_type"         => "code",
          "redirect_uri"          => redirect,
          "scope"                 => SCOPES,
          "code_challenge"        => challenge,
          "code_challenge_method" => "S256",
          "state"                 => verifier,
        })
        "#{authorize}?#{params}"
      end

      private def self.parse_manual(input : String) : {String, String?}
        stripped = input.strip
        code, state = case
                      when stripped.includes?('?')
                        params = URI::Params.parse(stripped.split('?', 2).last)
                        {params["code"]?, params["state"]?}
                      when stripped.includes?('#')
                        parts = stripped.split('#', 2)
                        {parts[0]?, parts[1]?}
                      when stripped.includes?("code=")
                        params = URI::Params.parse(stripped)
                        {params["code"]?, params["state"]?}
                      else
                        {stripped, nil}
                      end
        if code.nil? || code.empty?
          raise Error.new("Missing authorization code")
        end
        {code, state}
      end

      private def self.wait_code(server : OAuthCallbackServer, interaction : Interaction) : String
        callback = Channel(String | Exception).new(1)
        spawn do
          begin
            callback.send(server.wait)
          rescue ex
            callback.send(ex) rescue nil
          end
        end
        manual = Channel(String | Exception).new(1)
        spawn do
          begin
            manual.send(interaction.prompt(:manual_code, "Paste the authorization code or redirect URL:"))
          rescue ex
            manual.send(ex) rescue nil
          end
        end
        value = select
        when result = callback.receive
          result
        when input = manual.receive
          input
        end
        raise value if value.is_a?(Exception)
        value.as(String)
      end

      private def self.exchange_manual(token_url : String, input : String, verifier : String, redirect_uri : String) : OAuthCredential
        code, state = parse_manual(input)
        if state && state != verifier
          raise Error.new("OAuth state mismatch")
        end
        exchange(token_url, code, verifier, redirect_uri)
      end

      private def self.exchange(token_url : String, code : String, verifier : String, redirect_uri : String) : OAuthCredential
        body = {
          "grant_type"    => "authorization_code",
          "client_id"     => CLIENT_ID,
          "code"          => code,
          "state"         => verifier,
          "redirect_uri"  => redirect_uri,
          "code_verifier" => verifier,
        }.to_json
        post_token(token_url, body)
      rescue ex : Http::Error
        raise Error.new("OAuth token exchange failed: #{ex.message}")
      end

      private def self.post_token(token_url : String, body : String) : OAuthCredential
        response_body = ""
        Http.request(
          token_url,
          "POST",
          {"Content-Type" => "application/json", "Accept" => "application/json"},
          body,
          Http::Options.new(read_timeout: 30.seconds),
          nil,
        ) { |response| response_body = response.body_io.gets_to_end }
        parse_token(response_body, token_url)
      end

      private def self.parse_token(body : String, token_url : String) : OAuthCredential
        json = JSON.parse(body)
        access = json["access_token"]?.try(&.as_s)
        refresh = json["refresh_token"]?.try(&.as_s)
        expires_in = json["expires_in"]?.try(&.as_i)
        if access.nil? || refresh.nil? || expires_in.nil?
          raise Error.new("OAuth token response missing fields: #{token_url}")
        end
        OAuthCredential.new(refresh, access, Time.utc.to_unix_ms + expires_in.to_i64 * 1000 - EXPIRY_MARGIN_MS)
      end
    end
  end
end
