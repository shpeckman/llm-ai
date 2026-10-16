# src/llm/ai/sse.cr
module LLM::AI
  module SSE
    struct Event
      getter name : String?
      getter data : String

      def initialize(@name : String?, @data : String)
      end
    end

    class Reader
      @id     : String?
      @name   : String?
      @data   : Array(String)
      @buffer : String
      @eof    : Bool

      def initialize(@io : IO)
        @id     = nil
        @name   = nil
        @data   = [] of String
        @buffer = ""
        @eof    = false
      end

      def next : Event?
        while line = next_line
          if line.empty?
            return dispatch if pending?
            next
          end
          next if line.starts_with?(':')
          field, _, value = line.partition(':')
          value = value.lchop(' ')
          case field
          when "id"
            @id = value
          when "event"
            @name = value
          when "data"
            @data << value
          end
        end
        dispatch if pending?
      end

      private def next_line : String?
        loop do
          lf         = @buffer.byte_index('\n'.ord)
          cr         = @buffer.byte_index('\r'.ord)
          terminator = lf.nil? ? cr : (cr.nil? ? lf : Math.min(lf, cr))
          if terminator
            line    = @buffer.byte_slice(0, terminator)
            advance = terminator + 1
            if @buffer.byte_at(terminator) == '\r'.ord && advance < @buffer.bytesize && @buffer.byte_at(advance) == '\n'.ord
              advance += 1
            end
            @buffer = @buffer.byte_slice(advance)
            return line
          end
          break if @eof
          chunk = Bytes.new(4096)
          read  = @io.read(chunk)
          if read == 0
            @eof = true
          else
            @buffer += String.new(chunk[0, read])
          end
        end
        return nil if @buffer.empty?
        line    = @buffer
        @buffer = ""
        line
      end

      private def pending? : Bool
        !@data.empty? || !@name.nil?
      end

      private def dispatch : Event
        data = @data.join('\n')
        name = @name
        @data.clear
        @id   = nil
        @name = nil
        Event.new(name, data)
      end
    end
  end
end
