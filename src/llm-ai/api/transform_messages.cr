# src/llm-ai/api/transform_messages.cr
module LLM::AI::Transform
  def self.normalize(context : Context, target : Model) : Context
    messages = [] of Message
    id_map = {} of String => String
    pending_calls = [] of ToolCall
    answered_ids = Set(String).new
    held_system = [] of Message

    close_pending = -> {
      pending_calls.each do |call|
        unless answered_ids.includes?(call.id)
          messages << ToolResultMessage.new(
            call.id, call.name, [TextContent.new("No result provided")] of ContentBlock,
            Time.utc, true,
          )
        end
      end
      pending_calls.clear
      answered_ids.clear
      messages.concat(held_system)
      held_system.clear
    }

    context.messages.each do |message|
      case message
      when AssistantMessage
        close_pending.call
        next if message.stop_reason.error? || message.stop_reason.aborted?
        same_model = message.provider == target.provider && message.model == target.id
        blocks = message.content.compact_map { |block| convert_block(block, target, same_model, id_map) }
        calls = blocks.select(ToolCall)
        unless calls.empty?
          pending_calls = calls
          answered_ids = Set(String).new
        end
        messages << message.copy_with(content: blocks)
      when ToolResultMessage
        call_id = id_map.fetch(message.tool_call_id, message.tool_call_id)
        answered_ids << call_id
        blocks = message.content.compact_map { |block| convert_block(block, target, false, id_map) }
        messages << message.copy_with(tool_call_id: call_id, content: blocks)
      when UserMessage
        close_pending.call
        raw_content = message.content
        content = case raw_content
                  in String
                    raw_content
                  in Array(ContentBlock)
                    raw_content.compact_map { |block| convert_block(block, target, false, id_map) }
                  end
        messages << UserMessage.new(content, message.timestamp)
      when SystemMessage
        if pending_calls.empty?
          messages << message
        else
          held_system << message
        end
      else
        messages << message
      end
    end

    close_pending.call

    resolve_tools(messages, context, target)
  end

  private def self.resolve_tools(messages : Array(Message), context : Context, target : Model) : Context
    system_messages = [] of SystemMessage
    system_messages << SystemMessage.new("", Transcript::EPOCH, tools_added: context.tools) unless context.tools.empty?
    virtual = system_messages.size
    leading = virtual + (Transcript.initial_system_message(messages) ? 1 : 0)
    messages.each { |message| system_messages << message if message.is_a?(SystemMessage) }
    resolved = Transcript.resolve_tools(system_messages, leading, Transcript.tool_support(target))
    seen = virtual
    rewritten = messages.map do |message|
      next message unless message.is_a?(SystemMessage)
      folded = seen < resolved.folded_system_messages
      seen += 1
      next message unless folded && (message.tools_added || message.tools_removed)
      message.copy_with(tools_added: nil, tools_removed: nil).as(Message)
    end
    Context.new(rewritten, context.system_prompt, resolved.request_tools)
  end

  private def self.convert_block(block : ContentBlock, target : Model, same_model : Bool, id_map : Hash(String, String)) : ContentBlock?
    case block
    when ThinkingContent
      if block.redacted
        same_model ? block : nil
      elsif target.reasoning
        same_model ? block : ThinkingContent.new(block.thinking, nil, false)
      else
        TextContent.new(block.thinking)
      end
    when ToolCall
      normalized = normalize_id(block.id)
      if normalized != block.id
        id_map[block.id] = normalized
      end
      signature = same_model ? block.thought_signature : nil
      ToolCall.new(normalized, block.name, block.arguments, signature, block.namespace, block.arguments_error)
    when ImageContent
      if target.input.includes?(InputKind::Image)
        block
      else
        TextContent.new("(image omitted: model does not support images)")
      end
    else
      block
    end
  end

  private def self.normalize_id(id : String) : String
    normalized = id.gsub(/[^a-zA-Z0-9_-]/, "_")
    normalized.size > 64 ? normalized[0, 64] : normalized
  end
end
