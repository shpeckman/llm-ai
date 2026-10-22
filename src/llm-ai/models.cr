# src/llm/ai/models.cr
module LLM::AI
  class ModelsError < Exception
    getter kind : String

    def initialize(@kind : String, message : String)
      super(message)
    end
  end

  class MessageStream
    @channel : Channel(StreamEvent)
    @terminal : StreamEvent?
    @drained : Bool

    def initialize(@abort : AbortHandle? = nil)
      @channel = Channel(StreamEvent).new
      @terminal = nil
      @drained = false
    end

    def push(event : StreamEvent) : Nil
      @channel.send(event)
    end

    def finish(event : StreamEvent) : Nil
      @terminal = event
      @channel.send(event)
      @channel.close
    end

    def each(& : StreamEvent ->) : Nil
      while event = @channel.receive?
        yield event
      end
      @drained = true
    end

    def abort : Nil
      @abort.try(&.abort)
    end

    def result : AssistantMessage
      each { } unless @drained
      terminal = @terminal
      raise ModelsError.new("stream", "Stream ended without a terminal event") if terminal.nil?
      case terminal
      when StreamEvent::Done
        terminal.message
      when StreamEvent::Error
        if terminal.reason == :error
          raise ModelsError.new("stream", terminal.message.error_message || "Provider stream failed")
        end
        terminal.message
      else
        raise ModelsError.new("stream", "Stream ended without a terminal event")
      end
    end
  end

  struct Provider
    getter id : String
    getter name : String
    getter base_url : String
    getter headers : Hash(String, String)
    getter auth : Auth::ProviderAuth
    getter models : Array(Model)
    getter stream : Proc(Model, Context, StreamOptions, Auth::AuthResult, AbortHandle?, MessageStream)

    def initialize(@id, @name, @base_url, @headers, @auth, @models, @stream)
    end
  end

  class Models
    @providers : Hash(String, Provider)
    getter store : CredentialStore

    def initialize(@store : CredentialStore, @ctx : Auth::AuthContext)
      @providers = {} of String => Provider
    end

    def self.build(store : CredentialStore? = nil, ctx : Auth::AuthContext? = nil) : Models
      models = Models.new(store || FileCredentialStore.new, ctx || Auth::AuthContext.default)
      models.register(FauxProvider.provider)
      models.register(DeepSeekProvider.provider)
      models.register(AnthropicProvider.provider)
      models.register(KimiProvider.provider)
      models.register(MoonshotProvider.provider)
      models
    end

    def register(provider : Provider) : Nil
      @providers[provider.id] = provider
    end

    def provider(id : String) : Provider
      @providers[id]? || raise ModelsError.new("provider", "Unknown provider: #{id}")
    end

    def providers : Array(String)
      @providers.keys
    end

    def model(provider_id : String, model_id : String) : Model
      model = provider(provider_id).models.find { |candidate| candidate.id == model_id }
      model || raise ModelsError.new("provider", "Unknown model: #{provider_id}/#{model_id}")
    end

    def models_for(provider_id : String) : Array(Model)
      provider(provider_id).models
    end

    def stream(model : Model, context : Context, options : StreamOptions? = nil, abort : AbortHandle? = nil) : MessageStream
      provider = provider(model.provider)
      auth_result = Auth.resolve(model.provider, provider.auth, @store, @ctx)
      normalized = Transform.normalize(context, model)
      provider.stream.call(model, normalized, options || StreamOptions.new, auth_result, abort)
    end

    def chat(model : Model, context : Context, options : StreamOptions? = nil, abort : AbortHandle? = nil) : AssistantMessage
      stream(model, context, options, abort).result
    end
  end
end
