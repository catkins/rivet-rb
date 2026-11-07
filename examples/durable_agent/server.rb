$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require_relative "agent"

registry = Rivet::Registry.new(durable_agent: DurableAgent)
Signal.trap("INT") { registry.stop }
Signal.trap("TERM") { registry.stop }
registry.start(pool: ENV.fetch("RIVET_POOL_NAME", "default"))
