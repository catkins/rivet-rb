require "rivet"
require "securerandom"

client = Rivet::Client.new(
  ENV.fetch("RIVET_ENDPOINT", "http://127.0.0.1:6420"),
  token: ENV.fetch("RIVET_TOKEN", "dev"),
  pool: ENV.fetch("RIVET_POOL_NAME", "default")
)
counter = client.get_or_create(:counter, ["example", SecureRandom.hex(8)], input: {count: 10})
puts counter.increment(3)
puts counter.call(:increment, 2, timeout: 5)

counter.connect do |connection|
  subscription = connection.on(:newCount)
  puts connection.increment(4)
  p subscription.poll(timeout: 3)
end
