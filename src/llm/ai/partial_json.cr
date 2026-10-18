# src/llm/ai/partial_json.cr
require "json"

module LLM::AI::PartialJson
  extend self

  def parse(input : String) : JSON::Any
    JSON.parse(complete(input))
  rescue JSON::Error
    JSON::Any.new({} of String => JSON::Any)
  end

  def complete(input : String) : String
    stripped = input.lstrip
    return "" if stripped.empty?
    first = stripped[0]
    return stripped unless first == '"' || first == '{' || first == '['
    completed, stack, in_string = scan(stripped)
    completed += "\"" if in_string
    unless stack.empty?
      completed = completed.rstrip(", \t\r\n") unless in_string
      stack.reverse_each { |opening| completed += opening == '{' ? "}" : "]" }
    end
    completed
  end

  private def scan(input : String) : {String, Array(Char), Bool}
    io = String::Builder.new
    stack = [] of Char
    in_string = false
    escaped = false
    input.each_char do |char|
      io << char
      if in_string
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == '"'
          in_string = false
        end
      else
        case char
        when '"'
          in_string = true
        when '{', '['
          stack << char
        when '}'
          stack.pop if stack.last? == '{'
        when ']'
          stack.pop if stack.last? == '['
        end
      end
    end
    {io.to_s, stack, in_string}
  end
end
