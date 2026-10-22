# src/llm-ai/providers/moonshot.cr
module LLM::AI::MoonshotProvider
  def self.provider : Provider
    Provider.new(
      "moonshot", "Moonshot", "https://api.moonshot.ai", {} of String => String,
      Auth::ProviderAuth.new(Auth::ApiKeyAuth.new("Moonshot API key", ["MOONSHOT_API_KEY"])),
      ModelData.load("moonshot"),
      ->stream_for(Model, Context, StreamOptions, Auth::AuthResult, AbortHandle?),
    )
  end

  private def self.stream_for(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?) : MessageStream
    Api::OpenAICompletions.stream(model, context, options, auth, abort)
  end
end
