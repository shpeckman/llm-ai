# src/llm-ai/abort.cr
module LLM::AI
  class AbortHandle
    @channel : Channel(Nil)

    def initialize
      @channel = Channel(Nil).new
    end

    def abort : Nil
      @channel.close
      nil
    end

    def aborted? : Bool
      @channel.closed?
    end
  end

  class AbortError < Exception
  end
end
