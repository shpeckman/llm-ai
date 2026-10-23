# src/llm-ai/providers/deepseek_responses.cr
module LLM::AI::DeepSeekResponsesProvider
  def self.provider : Provider
    Provider.new(
      "deepseek-responses", "DeepSeek (Responses API)", "https://api.deepseek.com", {} of String => String,
      Auth::ProviderAuth.new(Auth::ApiKeyAuth.new("DeepSeek API key", ["DEEPSEEK_API_KEY"])),
      ModelData.load("deepseek-responses"),
      ->stream_for(Model, Context, StreamOptions, Auth::AuthResult, AbortHandle?),
    )
  end

  private def self.stream_for(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?) : MessageStream
    Api::Responses.stream(model, context, options, auth, abort)
  end
end
