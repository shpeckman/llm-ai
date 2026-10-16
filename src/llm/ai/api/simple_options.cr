# src/pi_ai/api/simple_options.cr
module LLM::AI
  struct ResolvedOptions
    getter max_tokens : Int32?
    getter temperature : Float64?
    getter thinking_enabled : Bool
    getter thinking_budget_tokens : Int32?
    getter effort : String?
    getter sampling_params : Hash(String, JSON::Any)

    def initialize(@max_tokens, @temperature, @thinking_enabled, @thinking_budget_tokens, @effort, @sampling_params)
    end
  end

  module SimpleOptions
    BUDGETS = {"minimal" => 1024, "low" => 2048, "medium" => 8192, "high" => 16384}

    def self.resolve(model : Model, options : StreamOptions) : ResolvedOptions
      thinking_enabled = model.reasoning && (options.thinking_enabled == true || !options.thinking_level.nil?)
      level = options.thinking_level
      budget = thinking_enabled ? budget_for(level) : nil
      effort = thinking_enabled ? effort_for(model, level) : nil
      max_tokens = options.max_tokens
      if thinking_enabled && max_tokens && budget
        resolved_max = Math.min(max_tokens + budget, model.max_tokens)
        if budget > resolved_max - 1024
          budget = Math.max(resolved_max - 1024, 0)
        end
        max_tokens = resolved_max
      end
      ResolvedOptions.new(max_tokens, options.temperature, thinking_enabled, budget, effort, merged_sampling(model, level, options))
    end

    private def self.budget_for(level : String?) : Int32
      case level
      when nil
        1024
      when "xhigh", "max"
        16384
      else
        BUDGETS[level]? || 1024
      end
    end

    private def self.effort_for(model : Model, level : String?) : String?
      if level
        model.thinking_level_map[level]?
      elsif model.compat.force_adaptive_thinking
        "high"
      end
    end

    private def self.merged_sampling(model : Model, level : String?, options : StreamOptions) : Hash(String, JSON::Any)
      merged = {} of String => JSON::Any
      model.sampling_params.try &.each { |key, value| merged[key] = value }
      if level
        model.sampling_params_by_thinking_level.try(&.[level]?).try &.each { |key, value| merged[key] = value }
      end
      options.sampling_params.try &.each { |key, value| merged[key] = value }
      merged
    end
  end
end
