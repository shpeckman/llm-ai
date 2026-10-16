# src/pi_ai/providers/kimi.cr
module LLM::AI
  module KimiProvider
    def self.provider : Provider
      Provider.new(
        "kimi-coding", "Kimi For Coding", "https://api.kimi.com", {} of String => String,
        Auth::ProviderAuth.new(
          Auth::ApiKeyAuth.new("Kimi API key", ["KIMI_API_KEY"]),
          Auth::OAuthAuth.new("Kimi", true, "Kimi subscription login",
            ->(interaction : Auth::Interaction, hosts : Auth::AuthHosts?) { Auth::Kimi.login(interaction) },
            ->(refresh_token : String, hosts : Auth::AuthHosts?) { Auth::Kimi.refresh(refresh_token) }),
        ),
        ModelData.load("kimi-coding"),
        ->stream_for(Model, Context, StreamOptions, Auth::AuthResult, AbortHandle?),
      )
    end

    private def self.stream_for(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?) : MessageStream
      Api::OpenAICompletions.stream(model, context, options, auth, abort)
    end
  end
end
