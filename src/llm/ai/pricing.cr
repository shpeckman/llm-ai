# src/llm/ai/pricing.cr
module LLM::AI::Pricing
  def self.calculate(model : Model, usage : Usage) : UsageCost
    tier             = tier_for(model.cost, usage.input)
    input_cost       = usage.input * tier.input / 1_000_000.0
    output_cost      = usage.output * tier.output / 1_000_000.0
    cache_read_cost  = usage.cache_read * tier.cache_read / 1_000_000.0
    cache_write_cost = cache_write_cost(tier, usage)
    UsageCost.new(
      input_cost,
      output_cost,
      cache_read_cost,
      cache_write_cost,
      input_cost + output_cost + cache_read_cost + cache_write_cost,
    )
  end

  private def self.tier_for(cost : ModelCost, input : Int32) : ModelCost
    selected = cost
    cost.tiers.each do |tier|
      selected = tier.cost if input > tier.above
    end
    selected
  end

  private def self.cache_write_cost(cost : ModelCost, usage : Usage) : Float64
    if one_hour = usage.cache_write_1h
      rate_1h = cost.cache_write_1h || cost.input * 2.0
      ((usage.cache_write - one_hour) * cost.cache_write + one_hour * rate_1h) / 1_000_000.0
    else
      usage.cache_write * cost.cache_write / 1_000_000.0
    end
  end
end
