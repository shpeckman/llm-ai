# src/llm-ai/auth.cr
module LLM::AI::Auth
  struct AuthContext
    getter env         : String -> String?
    getter file_exists : String -> Bool

    def initialize(@env : String -> String?, @file_exists : String -> Bool)
    end

    def self.default : AuthContext
      AuthContext.new(
        ->(name : String) { (value = ENV[name]?) && !value.empty? ? value : nil },
        ->(path : String) { File.exists?(path) },
      )
    end
  end

  struct ApiKeyAuth
    getter name     : String
    getter env_vars : Array(String)

    def initialize(@name : String, @env_vars : Array(String))
    end

    def resolve(ctx : AuthContext) : String?
      env_vars.each do |env_var|
        value = ctx.env.call(env_var)
        return value if value
      end
      nil
    end
  end

  struct OAuthAuth
    getter name            : String
    getter is_subscription : Bool
    getter login_label     : String
    getter login           : Proc(Interaction, AuthHosts?, OAuthCredential)
    getter refresh         : Proc(String, AuthHosts?, OAuthCredential)

    def initialize(@name : String, @is_subscription : Bool, @login_label : String,
                   @login : Proc(Interaction, AuthHosts?, OAuthCredential),
                   @refresh : Proc(String, AuthHosts?, OAuthCredential))
    end
  end

  struct ProviderAuth
    getter api_key : ApiKeyAuth?
    getter oauth   : OAuthAuth?

    def initialize(@api_key : ApiKeyAuth? = nil, @oauth : OAuthAuth? = nil)
    end
  end

  struct ModelAuth
    getter api_key  : String?
    getter headers  : Hash(String, String)?
    getter base_url : String?

    def initialize(@api_key : String? = nil, @headers : Hash(String, String)? = nil, @base_url : String? = nil)
    end
  end

  struct AuthResult
    getter auth   : ModelAuth
    getter source : String?

    def initialize(@auth : ModelAuth, @source : String? = nil)
    end
  end

  struct AuthOverrides
    getter api_key               : String?
    getter env                   : Hash(String, String)?
    getter min_oauth_validity_ms : Int64
    getter refresh_timeout       : Time::Span

    def initialize(@api_key : String? = nil, @env : Hash(String, String)? = nil, @min_oauth_validity_ms : Int64 = 300_000, @refresh_timeout : Time::Span = 15.seconds)
    end
  end

  def self.resolve(provider_id : String, auth : ProviderAuth, store : CredentialStore, ctx : AuthContext, overrides : AuthOverrides? = nil) : AuthResult
    overrides = overrides || AuthOverrides.new
    if override_key = overrides.api_key
      return AuthResult.new(ModelAuth.new(override_key, merged_headers(nil, overrides.env)), "override")
    end
    case credential = store.read(provider_id)
    when ApiKeyCredential
      if auth.api_key
        return AuthResult.new(ModelAuth.new(credential.key, merged_headers(nil, credential.env)), "stored credential")
      end
    when OAuthCredential
      if oauth_auth = auth.oauth
        fresh = stored_oauth(provider_id, oauth_auth, credential, store, overrides)
        return AuthResult.new(ModelAuth.new(fresh.access), "oauth") if fresh
      end
    end
    ambient(provider_id, auth, ctx, overrides)
  end

  def self.login(provider_id : String, auth : ProviderAuth, store : CredentialStore, interaction : Interaction, kind : Symbol) : Nil
    case kind
    when :api_key
      api_key_auth = auth.api_key || raise Error.new("Provider #{provider_id} has no API key auth")
      input        = interaction.prompt(:secret, "Enter #{api_key_auth.name}:")
      store.modify(provider_id) { ApiKeyCredential.new(input) }
    when :oauth
      oauth_auth = auth.oauth || raise Error.new("Provider #{provider_id} has no OAuth auth")
      credential = oauth_auth.login.call(interaction, nil)
      store.modify(provider_id) { credential }
    else
      raise Error.new("Unknown login kind: #{kind}")
    end
    nil
  end

  def self.logout(provider_id : String, store : CredentialStore) : Nil
    store.delete(provider_id)
    nil
  end

  def self.login(models : Models, provider_id : String, kind : Symbol, interaction : Interaction) : Nil
    login(provider_id, models.provider(provider_id).auth, models.store, interaction, kind)
  end

  def self.logout(models : Models, provider_id : String) : Nil
    logout(provider_id, models.store)
  end

  private def self.stored_oauth(provider_id : String, oauth_auth : OAuthAuth, credential : OAuthCredential, store : CredentialStore, overrides : AuthOverrides) : OAuthCredential?
    now = Time.utc.to_unix_ms
    return credential if credential.expires - now > overrides.min_oauth_validity_ms
    refresh_failure = nil
    result = store.modify(provider_id) do |current|
      current = current.as?(OAuthCredential)
      next current unless current
      next current if current.expires - Time.utc.to_unix_ms > overrides.min_oauth_validity_ms
      begin
        refresh_bounded(oauth_auth, current, overrides.refresh_timeout)
      rescue DeadCredential
        nil
      rescue ex : Error
        refresh_failure = ex
        current
      end
    end
    raise refresh_failure.not_nil! if refresh_failure
    result
  end

  private def self.refresh_bounded(oauth_auth : OAuthAuth, credential : OAuthCredential, timeout_span : Time::Span) : OAuthCredential
    channel = Channel(OAuthCredential | Exception).new
    spawn do
      channel.send(oauth_auth.refresh.call(credential.refresh, nil))
    rescue ex
      channel.send(ex) rescue nil
    end
    value = select
    when result = channel.receive
      result
    when timeout(timeout_span)
      raise Error.new("OAuth refresh timed out")
    end
    raise value if value.is_a?(Exception)
    value.as(OAuthCredential)
  end

  private def self.ambient(provider_id : String, auth : ProviderAuth, ctx : AuthContext, overrides : AuthOverrides) : AuthResult
    if provider_id == "anthropic" && (token = ctx.env.call("ANTHROPIC_AUTH_TOKEN"))
      return AuthResult.new(ModelAuth.new(nil, {"Authorization" => "Bearer #{token}"}), "ambient env")
    end
    if (api_key_auth = auth.api_key) && (key = api_key_auth.resolve(ctx))
      return AuthResult.new(ModelAuth.new(key), "ambient env")
    end
    AuthResult.new(ModelAuth.new)
  end

  private def self.merged_headers(base : Hash(String, String)?, extra : Hash(String, String)?) : Hash(String, String)?
    return base if extra.nil?
    merged = base ? base.dup : {} of String => String
    extra.each { |key, value| merged[key] = value }
    merged
  end
end
