# src/llm-ai/identity.cr
require "json"
require "uri"

module LLM::AI
  enum UserAgentMode
    Short
    Detailed
  end

  struct ClientAttribution
    include JSON::Serializable

    getter name : String
    getter url : String
    getter categories : Array(String)?

    def initialize(@name : String, @url : String, @categories : Array(String)? = nil)
    end
  end

  module UserAgentConverter
    def self.from_json(pull : JSON::PullParser) : UserAgentMode | String
      value = pull.read_string
      UserAgentMode.parse?(value) || value
    end

    def self.to_json(value : UserAgentMode | String, json : JSON::Builder) : Nil
      json.string(value.is_a?(UserAgentMode) ? value.to_s.downcase : value)
    end
  end

  struct ClientIdentity
    include JSON::Serializable

    @[JSON::Field(converter: LLM::AI::UserAgentConverter)]
    getter user_agent : (UserAgentMode | String)?
    getter attribution : ClientAttribution?
    getter version : String?

    def initialize(@user_agent : (UserAgentMode | String)? = nil, @attribution : ClientAttribution? = nil, @version : String? = nil)
    end
  end

  module Identity
    PRODUCT         = "llm-ai"
    NVIDIA_NIM_HOST = "integrate.api.nvidia.com"
    OPENCODE_HOST   = "opencode.ai"
    PLATFORM        = {% if flag?(:linux) %}"linux"{% elsif flag?(:darwin) %}"darwin"{% elsif flag?(:win32) %}"win32"{% elsif flag?(:freebsd) %}"freebsd"{% elsif flag?(:openbsd) %}"openbsd"{% else %}"unknown"{% end %}
    ARCH            = {% if flag?(:x86_64) %}"x86_64"{% elsif flag?(:aarch64) %}"aarch64"{% elsif flag?(:arm) %}"arm"{% elsif flag?(:i386) %}"i386"{% else %}"unknown"{% end %}

    def self.version(identity : ClientIdentity?) : String
      identity.try(&.version) || VERSION
    end

    def self.user_agent(identity : ClientIdentity?) : String
      case mode = identity.try(&.user_agent) || UserAgentMode::Detailed
      in String
        mode
      in UserAgentMode
        mode.short? ? PRODUCT : "#{PRODUCT}/#{version(identity)} (#{PLATFORM}; crystal/#{Crystal::VERSION}; #{ARCH})"
      end
    end

    def self.attribution_headers(model : Model, identity : ClientIdentity?) : Hash(String, String)
      headers = {} of String => String
      attribution = identity.try(&.attribution)
      return headers unless attribution
      if open_router?(model)
        headers["HTTP-Referer"] = attribution.url
        headers["X-OpenRouter-Title"] = attribution.name
        if (categories = attribution.categories) && !categories.empty?
          headers["X-OpenRouter-Categories"] = categories.join(",")
        end
      elsif nvidia_nim?(model)
        name = attribution.name
        headers["X-BILLING-INVOKE-ORIGIN"] = "#{name[0]?.try(&.upcase)}#{name[1..]?}"
      elsif open_code?(model)
        headers["x-opencode-client"] = attribution.name
      end
      headers
    end

    def self.headers(model : Model, identity : ClientIdentity?) : Hash(String, String)
      headers = {"User-Agent" => user_agent(identity)}
      headers.merge!(attribution_headers(model, identity))
      headers
    end

    private def self.open_router?(model : Model) : Bool
      model.provider == "openrouter" || model.base_url.includes?("openrouter.ai")
    end

    private def self.nvidia_nim?(model : Model) : Bool
      model.provider == "nvidia" || host?(model.base_url, NVIDIA_NIM_HOST)
    end

    private def self.open_code?(model : Model) : Bool
      model.provider == "opencode" || model.provider == "opencode-go" || host?(model.base_url, OPENCODE_HOST)
    end

    private def self.host?(base_url : String, expected : String) : Bool
      URI.parse(base_url).host == expected
    rescue URI::Error
      false
    end
  end
end
