# src/llm-ai/abort.cr
module LLM::AI
  class AbortError < Exception
  end

  class AbortHandle
    NOOP_REMOVER = -> { nil }

    getter reason : Exception? = nil
    getter? aborted : Bool = false
    @listeners = {} of Int32 => Proc(Exception, Nil)
    @next_listener = 0

    def abort(reason : Exception = AbortError.new("The operation was aborted")) : Nil
      return if @aborted
      @aborted = true
      @reason = reason
      listeners = @listeners.values
      @listeners.clear
      failure = nil
      listeners.each do |listener|
        listener.call(reason)
      rescue error
        failure ||= error
      end
      failure.try { |error| raise error }
    end

    def abort(message : String) : Nil
      abort(AbortError.new(message))
    end

    def on_abort(&listener : Exception -> Nil) : Proc(Nil)
      return NOOP_REMOVER if @aborted
      id = @next_listener
      @next_listener += 1
      @listeners[id] = listener
      remover(id)
    end

    def throw_if_aborted : Nil
      if reason = @reason
        raise reason
      end
    end

    private def remover(id : Int32) : Proc(Nil)
      -> { @listeners.delete(id); nil }
    end
  end
end
