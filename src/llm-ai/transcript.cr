# src/llm-ai/transcript.cr
module LLM::AI
  enum ToolSupport
    None
    Additions
    Changes
  end

  record ToolStateChanges, tools_added : Array(Tool), tools_removed : Array(ToolReference)

  record TranscriptTools, request_tools : Array(Tool), folded_system_messages : Int32

  module Transcript
    EPOCH = Time.unix_ms(0)

    def self.create_initial_system_message(system_prompt : String?, tools : Array(Tool)?) : SystemMessage?
      has_prompt = !system_prompt.nil? && !system_prompt.empty?
      has_tools = !tools.nil? && !tools.empty?
      return unless has_prompt || has_tools
      SystemMessage.new(system_prompt || "", EPOCH, tools_added: has_tools ? tools : nil)
    end

    def self.initial_system_message(messages : Array(T)) : SystemMessage? forall T
      messages.first?.as?(SystemMessage)
    end

    def self.current_tools(messages : Array(T)) : Array(Tool) forall T
      tools = {} of String => Tool
      messages.each do |message|
        next unless message.is_a?(SystemMessage)
        message.tools_removed.try &.each { |tool| tools.delete(tool.name) }
        message.tools_added.try &.each { |tool| tools[tool.name] = tool }
      end
      tools.values
    end

    def self.current_system_message(messages : Array(T)) : SystemMessage? forall T
      content = [] of String
      sections = {} of String => String
      timestamp = nil
      messages.each do |message|
        next unless message.is_a?(SystemMessage)
        timestamp ||= message.timestamp
        text = content_text(message.content)
        content << text unless text.empty?
        message.sections.try &.each do |name, value|
          if value
            sections[name] = value
          else
            sections.delete(name)
          end
        end
      end
      tools = current_tools(messages)
      return if timestamp.nil? && tools.empty?
      SystemMessage.new(
        content.join("\n\n"),
        timestamp || EPOCH,
        sections.empty? ? nil : sections.transform_values { |value| value.as(String?) },
        tools.empty? ? nil : tools,
      )
    end

    def self.current_system_prompt(messages : Array(T)) : String forall T
      current_system_message(messages).try { |message| system_text(message) } || ""
    end

    def self.tool_state_changes(previous : Array(Tool), current : Array(Tool)) : ToolStateChanges
      previous_by_name = previous.to_h { |tool| {tool.name, tool} }
      current_by_name = current.to_h { |tool| {tool.name, tool} }
      added = current.select { |tool| previous_by_name[tool.name]? != tool }
      removed = previous.reject { |tool| current_by_name[tool.name]? == tool }.map { |tool| ToolReference.new(tool.name) }
      ToolStateChanges.new(added, removed)
    end

    def self.tool_support(model : Model) : ToolSupport
      compat = model.compat
      return ToolSupport::None unless compat.supports_mid_convo_system_messages
      return ToolSupport::Changes if compat.supports_mid_convo_tool_changes
      return ToolSupport::Additions if compat.supports_mid_convo_tool_additions
      ToolSupport::None
    end

    def self.resolve_tools(system_messages : Array(SystemMessage), leading : Int32, support : ToolSupport) : TranscriptTools
      folded = case support
               in ToolSupport::None      then system_messages.size
               in ToolSupport::Changes   then leading
               in ToolSupport::Additions then Math.max(leading, last_non_additive_change(system_messages) + 1)
               end
      folded = Math.min(folded, system_messages.size)
      TranscriptTools.new(current_tools(system_messages[0, folded]), folded)
    end

    def self.system_text(message : SystemMessage) : String
      parts = [content_text(message.content)]
      message.sections.try &.each_value { |value| parts << value if value }
      parts.reject(&.empty?).join("\n\n")
    end

    def self.system_update_text(message : SystemMessage) : String
      parts = [] of String
      text = content_text(message.content)
      parts << text unless text.empty?
      message.sections.try &.each do |name, value|
        parts << (value ? "Updated system prompt section \"#{name}\":\n\n#{value}" : "Removed system prompt section \"#{name}\".")
      end
      parts.join("\n\n")
    end

    def self.content_text(content : String) : String
      content
    end

    def self.content_text(content : Array(TextContent)) : String
      content.join("\n", &.text)
    end

    private def self.last_non_additive_change(system_messages : Array(SystemMessage)) : Int32
      declared = Set(String).new
      last = -1
      system_messages.each_with_index do |message, index|
        last = index if message.tools_removed.try(&.empty?) == false
        message.tools_added.try &.each do |tool|
          last = index if declared.includes?(tool.name)
          declared << tool.name
        end
      end
      last
    end
  end
end
