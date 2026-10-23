# src/llm-ai/providers/moonshot_anthropic.cr
module LLM::AI::MoonshotAnthropicProvider
  def self.provider : Provider
    Provider.new(
      "moonshot-anthropic", "Moonshot (Anthropic API)", "https://api.moonshot.ai/anthropic", {} of String => String,
      Auth::ProviderAuth.new(Auth::ApiKeyAuth.new("Moonshot API key", ["MOONSHOT_API_KEY"])),
      ModelData.load("moonshot-anthropic"),
      ->stream_for(Model, Context, StreamOptions, Auth::AuthResult, AbortHandle?),
    )
  end

  private def self.stream_for(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?) : MessageStream
    Api::AnthropicMessages.stream(model, context, options, auth, abort)
  end
end
