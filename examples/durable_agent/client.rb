$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "rivet"
require "securerandom"

if $PROGRAM_NAME == __FILE__
  client = Rivet::Client.new(pool: ENV.fetch("RIVET_POOL_NAME", "default"))
  agent = client.get_or_create(:durable_agent, [ENV.fetch("AGENT_KEY", "demo")])
  request_id = ENV.fetch("REQUEST_ID") { SecureRandom.uuid }
  prompt = ARGV.empty? ? "Remember that my favourite colour is green, then tell me what you remembered." : ARGV.join(" ")
  puts JSON.generate(agent.submit(prompt, request_id))
  puts "Run #{request_id}; reuse REQUEST_ID with the same prompt after a disconnect."

  loop do
    snapshot = agent.snapshot
    run = snapshot.fetch("runs").find { |entry| entry.fetch("id") == request_id }
    if %w[completed cancelled failed].include?(run.fetch("status"))
      puts JSON.pretty_generate(snapshot)
      break
    end
    sleep 0.5
  end
end
