require "rivet"

class Counter < Rivet::Actor
  state do |_ctx, input|
    {"count" => input&.fetch("count", 0) || 0}
  end

  action :increment do |ctx, amount = 1|
    count = ctx.update_state { |state| state["count"] += amount }
    ctx.broadcast(:newCount, count)
    count
  end

  action :count do |ctx|
    ctx.state.fetch("count")
  end
end
