# src/llm-ai/auth/credential_store.cr
require "json"

module LLM::AI
  abstract class Credential
    include JSON::Serializable
    use_json_discriminator "type", {
      api_key: ApiKeyCredential,
      oauth:   OAuthCredential,
    }

    abstract def type_name : String
  end

  class ApiKeyCredential < Credential
    include JSON::Serializable

    getter key : String?
    getter env : Hash(String, String)?

    def initialize(@key : String? = nil, @env : Hash(String, String)? = nil)
    end

    def type_name : String
      "api_key"
    end

    def ==(other : ApiKeyCredential) : Bool
      key == other.key && env == other.env
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "api_key"
    end
  end

  class OAuthCredential < Credential
    include JSON::Serializable

    getter refresh : String
    getter access : String
    getter expires : Int64
    getter extra : Hash(String, JSON::Any)

    def initialize(@refresh : String, @access : String, @expires : Int64, @extra : Hash(String, JSON::Any) = Hash(String, JSON::Any).new)
    end

    def type_name : String
      "oauth"
    end

    def ==(other : OAuthCredential) : Bool
      refresh == other.refresh && access == other.access && expires == other.expires && extra == other.extra
    end

    protected def on_to_json(json : JSON::Builder)
      json.field "type", "oauth"
    end
  end

  struct CredentialInfo
    include JSON::Serializable

    getter provider_id : String
    getter type : String

    def initialize(@provider_id : String, @type : String)
    end

    def ==(other : CredentialInfo) : Bool
      provider_id == other.provider_id && type == other.type
    end
  end

  abstract class CredentialStore
    abstract def read(provider_id : String) : Credential?
    abstract def list : Array(CredentialInfo)
    abstract def modify(provider_id : String, & : Credential? -> Credential?) : Credential?
    abstract def delete(provider_id : String) : Nil
  end

  class FileCredentialStore < CredentialStore
    getter path : Path

    def initialize(path : Path? = nil)
      @path = path || Path.home / ".config/pi-ai-cr/auth.json"
    end

    def read(provider_id : String) : Credential?
      read_all[provider_id]?
    end

    def list : Array(CredentialInfo)
      read_all.map { |provider_id, credential| CredentialInfo.new(provider_id, credential.type_name) }
    end

    def modify(provider_id : String, & : Credential? -> Credential?) : Credential?
      with_lock do
        all = read_all
        updated = yield all[provider_id]?
        if updated
          all[provider_id] = updated
        else
          all.delete(provider_id)
        end
        write_all(all)
        updated
      end
    end

    def delete(provider_id : String) : Nil
      with_lock do
        all = read_all
        if all.delete(provider_id)
          write_all(all)
        end
      end
      nil
    end

    private def read_all : Hash(String, Credential)
      return Hash(String, Credential).new unless File.exists?(@path)
      Hash(String, Credential).from_json(File.read(@path))
    rescue JSON::ParseException | JSON::SerializableError | IO::Error
      Hash(String, Credential).new
    end

    private def write_all(all : Hash(String, Credential)) : Nil
      Dir.mkdir_p(@path.dirname.to_s, 0o700)
      tmp = "#{@path}.tmp.#{Process.pid}"
      begin
        File.open(tmp, "w", 0o600) do |file|
          all.to_json(file)
        end
        File.rename(tmp, @path.to_s)
      ensure
        File.delete(tmp) if File.exists?(tmp)
      end
      File.chmod(@path.to_s, 0o600)
    end

    private def with_lock(&)
      Dir.mkdir_p(@path.dirname.to_s, 0o700)
      File.open("#{@path}.lock", "a", 0o600) do |lock_file|
        lock_file.flock_exclusive
        begin
          yield
        ensure
          lock_file.flock_unlock
        end
      end
    end
  end
end
