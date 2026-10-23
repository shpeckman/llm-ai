# src/llm-ai/providers/deepseek_anthropic.cr
module LLM::AI::DeepSeekAnthropicProvider
  def self.provider : Provider
    Provider.new(
      "deepseek-anthropic", "DeepSeek (Anthropic API)", "https://api.deepseek.com/anthropic", {} of String => String,
      Auth::ProviderAuth.new(Auth::ApiKeyAuth.new("DeepSeek API key", ["DEEPSEEK_API_KEY"])),
      ModelData.load("deepseek-anthropic"),
      ->stream_for(Model, Context, StreamOptions, Auth::AuthResult, AbortHandle?),
    )
  end

  private def self.stream_for(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?) : MessageStream
    Api::AnthropicMessages.stream(model, context, options, auth, abort)
  end
end
