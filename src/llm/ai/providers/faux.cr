# src/pi_ai/providers/faux.cr
module LLM::AI
  module FauxProvider
    def self.provider : Provider
      Provider.new(
        "faux", "Faux", "http://faux.local", {} of String => String,
        Auth::ProviderAuth.new,
        [
          Model.new("faux-chat", "Faux Chat", "faux", "http://faux.local", ApiKind::OpenaiCompletions,
            [InputKind::Text], 4096, 1024, false, ModelCost.new(0.0, 0.0, 0.0, 0.0, nil)),
          Model.new("faux-error", "Faux Error", "faux", "http://faux.local", ApiKind::OpenaiCompletions,
            [InputKind::Text], 4096, 1024, false, ModelCost.new(0.0, 0.0, 0.0, 0.0, nil)),
        ],
        ->stream_for(Model, Context, StreamOptions, Auth::AuthResult, AbortHandle?),
      )
    end

    private def self.stream_for(model : Model, context : Context, options : StreamOptions, auth : Auth::AuthResult, abort : AbortHandle?) : MessageStream
      stream = MessageStream.new(abort)
      spawn do
        started_at = Time.instant
        partial = AssistantMessage.new([] of ContentBlock, "faux", model.id, Time.utc)
        stream.push(StreamEvent::Start.new(partial))
        case model.id
        when "faux-error"
          failed = AssistantMessage.new(partial.content, "faux", model.id, Time.utc, error_message: "faux error", stop_reason: StopReason::Error)
          stream.finish(StreamEvent::Error.new(:error, failed))
        else
          text = TextContent.new("hello")
          updated = AssistantMessage.new([text] of ContentBlock, "faux", model.id, Time.utc)
          stream.push(StreamEvent::TextDelta.new(0, "hello", updated))
          if abort
            loop do
              break if abort.aborted?
              sleep 5.milliseconds
            end
            aborted = AssistantMessage.new([text] of ContentBlock, "faux", model.id, Time.utc, stop_reason: StopReason::Aborted, duration_ms: elapsed_ms(started_at))
            stream.finish(StreamEvent::Error.new(:aborted, aborted))
          else
            final = AssistantMessage.new([text] of ContentBlock, "faux", model.id, Time.utc, stop_reason: StopReason::Stop, duration_ms: elapsed_ms(started_at))
            stream.finish(StreamEvent::Done.new(StopReason::Stop, final))
          end
        end
      end
      stream
    end

    private def self.elapsed_ms(started_at : Time::Instant) : Int64
      (Time.instant - started_at).total_milliseconds.to_i64
    end
  end
end
