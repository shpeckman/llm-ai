# src/llm/ai/providers/anthropic.cr
module LLM::AI::AnthropicProvider
  def self.provider : Provider
    Provider.new(
      "anthropic", "Anthropic", "https://api.anthropic.com", {} of String => String,
      Auth::ProviderAuth.new(
        Auth::ApiKeyAuth.new("Anthropic API key", ["ANTHROPIC_API_KEY", "ANTHROPIC_OAUTH_TOKEN"]),
        Auth::OAuthAuth.new("Anthropic", true, "Anthropic subscription login",
          ->(interaction : Auth::Interaction, hosts : Auth::AuthHosts?) { Auth::Anthropic.login(interaction, hosts: hosts) },
          ->(refresh_token : String, hosts : Auth::AuthHosts?) { Auth::Anthropic.refresh(refresh_token, hosts) }),
      ),
      ModelData.load("anthropic"),
      ->stream_for(Model, Context, StreamOptions, Auth::AuthResult, AbortHandle?),
    )
  end

  private def self.stream_for(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?) : MessageStream
    Api::AnthropicMessages.stream(model, context, options, auth, abort)
  end
end
