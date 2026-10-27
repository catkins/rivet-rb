$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require_relative "counter"
require_relative "kitchen_sink"

registry = Rivet::Registry.new(counter: Counter, kitchen_sink: KitchenSink)
Signal.trap("INT") { registry.stop }
Signal.trap("TERM") { registry.stop }
registry.start(pool: ENV.fetch("RIVET_POOL_NAME", "default"))
