# src/llm/ai/providers/deepseek.cr
module LLM::AI::DeepSeekProvider
  def self.provider : Provider
    Provider.new(
      "deepseek", "DeepSeek", "https://api.deepseek.com", {} of String => String,
      Auth::ProviderAuth.new(Auth::ApiKeyAuth.new("DeepSeek API key", ["DEEPSEEK_API_KEY"])),
      ModelData.load("deepseek"),
      ->stream_for(Model, Context, StreamOptions, Auth::AuthResult, AbortHandle?),
    )
  end

  private def self.stream_for(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?) : MessageStream
    Api::OpenAICompletions.stream(model, context, options, auth, abort)
  end
end
