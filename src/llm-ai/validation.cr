# src/llm-ai/validation.cr
require "json"
require "typebox"

module LLM::AI
  class ToolValidationError < Exception
  end

  module Validation
    JSON_TYPES = {"number", "integer", "boolean", "string", "null", "array", "object"}

    def self.validate_tool_call(tools : Array(Tool), tool_call : ToolCall) : JSON::Any
      tool = tools.find { |candidate| candidate.name == tool_call.name }
      raise ToolValidationError.new("Tool \"#{tool_call.name}\" not found") unless tool
      validate_tool_arguments(tool, tool_call)
    end

    def self.validate_tool_arguments(tool : Tool, tool_call : ToolCall) : JSON::Any
      validate_arguments(tool.parameters, tool_call)
    end

    def self.validate_arguments(schema : JSON::Any, tool_call : ToolCall) : JSON::Any
      if parse_error = tool_call.arguments_error
        raise ToolValidationError.new("Invalid arguments for tool \"#{tool_call.name}\": #{parse_error}")
      end
      args = deep_copy(tool_call.arguments)
      normalize_optional_nulls(args, schema)
      args = coerce(args, schema)
      return args if check?(schema, args)
      errors = TypeBox::Value.errors(schema, args).map { |error| "  - #{path(error)}: #{error.message}" }
      details = errors.empty? ? "Unknown validation error" : errors.join("\n")
      raise ToolValidationError.new(
        "Validation failed for tool \"#{tool_call.name}\":\n#{details}\n\nReceived arguments:\n#{tool_call.arguments.to_pretty_json}"
      )
    end

    def self.deep_copy(value : JSON::Any) : JSON::Any
      case raw = value.raw
      when Array
        JSON::Any.new(raw.map { |item| deep_copy(item) })
      when Hash
        JSON::Any.new(raw.transform_values { |item| deep_copy(item) })
      else
        value
      end
    end

    private def self.check?(schema : JSON::Any, value : JSON::Any?) : Bool
      TypeBox::Value.check(schema, value)
    rescue
      false
    end

    private def self.path(error : TypeBox::ValidationError) : String
      base = error.instance_path.lchop('/').gsub('/', '.')
      if error.keyword == "required" && (property = error.params["requiredProperties"]?.try(&.as_a?).try(&.first?).try(&.as_s?))
        return base.empty? ? property : "#{base}.#{property}"
      end
      base.empty? ? "root" : base
    end

    private def self.schema_types(schema : JSON::Any) : Array(String)
      case type = schema["type"]?.try(&.raw)
      when String then [type]
      when Array  then type.compact_map(&.as_s?)
      else             [] of String
      end
    end

    private def self.matches_type?(value : JSON::Any, type : String) : Bool
      case raw = value.raw
      when Int64   then type == "number" || type == "integer"
      when Float64 then type == "number" || (type == "integer" && raw.finite? && raw == raw.trunc)
      when Bool    then type == "boolean"
      when String  then type == "string"
      when Nil     then type == "null"
      when Array   then type == "array"
      when Hash    then type == "object"
      else              false
      end
    end

    private def self.number(value : Float64) : JSON::Any
      value == value.trunc && value.abs < 2.0 ** 53 ? JSON::Any.new(value.to_i64) : JSON::Any.new(value)
    end

    private def self.text(value : JSON::Any) : String
      case raw = value.raw
      when Float64 then raw == raw.trunc && raw.abs < 2.0 ** 53 ? raw.to_i64.to_s : raw.to_s
      else              raw.to_s
      end
    end

    private def self.coerce_primitive(value : JSON::Any, type : String) : JSON::Any?
      raw = value.raw
      case type
      when "number"
        case raw
        when Nil    then JSON::Any.new(0_i64)
        when Bool   then JSON::Any.new(raw ? 1_i64 : 0_i64)
        when String then raw.strip.empty? ? nil : raw.to_f?.try { |parsed| number(parsed) if parsed.finite? }
        end
      when "integer"
        case raw
        when Nil    then JSON::Any.new(0_i64)
        when Bool   then JSON::Any.new(raw ? 1_i64 : 0_i64)
        when String then raw.strip.empty? ? nil : raw.to_f?.try { |parsed| JSON::Any.new(parsed.to_i64) if parsed.finite? && parsed == parsed.trunc }
        end
      when "boolean"
        case raw
        when Nil            then JSON::Any.new(false)
        when String         then raw == "true" ? JSON::Any.new(true) : (raw == "false" ? JSON::Any.new(false) : nil)
        when Int64, Float64 then raw == 1 ? JSON::Any.new(true) : (raw == 0 ? JSON::Any.new(false) : nil)
        end
      when "string"
        case raw
        when Nil                  then JSON::Any.new("")
        when Int64, Float64, Bool then JSON::Any.new(text(value))
        end
      when "null"
        JSON::Any.new(nil) if raw == "" || raw == 0 || raw == false
      end
    end

    private def self.coerce(value : JSON::Any, schema : JSON::Any) : JSON::Any
      return value unless schema.as_h?
      result = value
      schema["allOf"]?.try(&.as_a?).try &.each { |nested| result = coerce(result, nested) }
      schema["anyOf"]?.try(&.as_a?).try { |schemas| result = coerce_union(result, schemas) }
      schema["oneOf"]?.try(&.as_a?).try { |schemas| result = coerce_union(result, schemas) }
      types = schema_types(schema).select { |type| JSON_TYPES.includes?(type) }
      unless types.empty? || (types.size > 1 && types.any? { |type| matches_type?(result, type) })
        types.each do |type|
          if candidate = coerce_primitive(result, type)
            result = candidate
            break
          end
        end
      end
      if types.includes?("object") && (hash = result.as_h?)
        coerce_object(hash, schema)
      end
      if types.includes?("array") && (array = result.as_a?)
        coerce_array(array, schema)
      end
      result
    end

    private def self.coerce_object(value : Hash(String, JSON::Any), schema : JSON::Any) : Nil
      properties = schema["properties"]?.try(&.as_h?)
      properties.try &.each do |key, property|
        if current = value[key]?
          value[key] = coerce(current, property)
        end
      end
      additional = schema["additionalProperties"]?
      return unless additional && additional.as_h?
      value.each do |key, item|
        next if properties.try(&.has_key?(key))
        value[key] = coerce(item, additional)
      end
    end

    private def self.coerce_array(value : Array(JSON::Any), schema : JSON::Any) : Nil
      items = schema["items"]?
      return unless items
      if tuple = items.as_a?
        value.each_index do |index|
          item_schema = tuple[index]?
          value[index] = coerce(value[index], item_schema) if item_schema
        end
      elsif items.as_h?
        value.each_index { |index| value[index] = coerce(value[index], items) }
      end
    end

    private def self.coerce_union(value : JSON::Any, schemas : Array(JSON::Any)) : JSON::Any
      return value if schemas.any? { |schema| check?(schema, value) }
      schemas.each do |schema|
        coerced = coerce(deep_copy(value), schema)
        return coerced if check?(schema, coerced)
      end
      value
    end

    private def self.normalize_optional_nulls(value : JSON::Any, schema : JSON::Any) : Nil
      return unless schema.as_h?
      if array = value.as_a?
        items = schema["items"]?
        if tuple = items.try(&.as_a?)
          array.each_with_index { |item, index| tuple[index]?.try { |item_schema| normalize_optional_nulls(item, item_schema) } }
        elsif items
          array.each { |item| normalize_optional_nulls(item, items) }
        end
        return
      end
      object = value.as_h?
      properties = schema["properties"]?.try(&.as_h?)
      return unless object && properties
      required = schema["required"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      properties.each do |key, property|
        next unless current = object[key]?
        reference = property.as_h?.try(&.["$ref"]?).try(&.as_s?)
        if current.raw.nil? && !required.includes?(key) && reference.nil? && !null_allowed?(property)
          object.delete(key)
        else
          normalize_optional_nulls(current, property)
        end
      end
    end

    private def self.null_allowed?(schema : JSON::Any) : Bool
      TypeBox::Value.check(schema, JSON::Any.new(nil))
    rescue
      true
    end
  end
end
