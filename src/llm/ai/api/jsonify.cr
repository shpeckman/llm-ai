# src/llm/ai/api/jsonify.cr
require "json"

module LLM::AI
  module Jsonify
    extend self

    def any(json : JSON::Builder, value : JSON::Any) : Nil
      case raw = value.raw
      when Nil
        json.null
      when Bool
        json.bool(raw)
      when String
        json.string(raw)
      when Int64
        json.number(raw)
      when Float64
        json.number(raw)
      when Array(JSON::Any)
        json.array do
          raw.each { |item| any(json, item) }
        end
      when Hash(String, JSON::Any)
        json.object do
          raw.each { |key, item| json.field(key) { any(json, item) } }
        end
      end
    end
  end
end
