#!/usr/bin/env bash
# Run from the repository root with the stack running. Optional Compose flags:
# bash test/runner_restart.sh -f compose.yaml -f docker/compose.host.yaml
set -euo pipefail
compose=(docker compose "$@")

# Keep the saved identity in the container so the second client resolves the same actor.
trap '"${compose[@]}" exec -T runner rm -f /tmp/rivet-rb-restart.json' EXIT
"${compose[@]}" exec -T runner bundle exec ruby -Ilib <<'RUBY'
require "rivet"
require "securerandom"
require "json"
client = Rivet::Client.new(pool: ENV.fetch("RIVET_POOL_NAME", "default"))
actor = client.get_or_create(:kitchen_sink, ["restart-test", SecureRandom.hex(8)], input: {"label" => "restart"})
actor.sql_put("durable", "SQLite after runner restart")
actor.kv_put("durable", {"answer" => 73})
before = actor.info
File.write("/tmp/rivet-rb-restart.json", JSON.generate(before))
puts "Before restart: #{JSON.generate(before)}"
RUBY

# Restart the runner only: the engine and its storage stay up. This requests graceful shutdown,
# but the SDK may reach its drain deadline. It does not test unsaved-state SIGKILL durability.
"${compose[@]}" restart runner
"${compose[@]}" exec -T runner bundle exec ruby -Ilib <<'RUBY'
require "rivet"
require "json"
before = JSON.parse(File.read("/tmp/rivet-rb-restart.json"))
client = Rivet::Client.new(pool: ENV.fetch("RIVET_POOL_NAME", "default"))
actor = client.get_for_id(:kitchen_sink, before.fetch("id"))
# Preview can wait for the old runner's lost threshold (~40s) before reactivating.
# Retry only this read-only probe: the gateway can also expire a request during recovery.
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
after = loop do
  begin
    break actor.call(:info, timeout: 10)
  rescue Rivet::Error => error
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    raise unless error.message.include?("deadline") && elapsed < 90
    warn "Recovery probe at #{elapsed.round(2)}s: #{error.message}"
    sleep 1
  end
end
puts "Recovery request: #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)}s"
raise "actor identity changed" unless after.fetch("id") == before.fetch("id")
raise "activation did not change" if after.fetch("activation") == before.fetch("activation")
raise "input lost" unless after.fetch("state").fetch("input") == {"label" => "restart"}
raise "actor recreated" unless after.fetch("state").fetch("created") == 1
raise "start count lost" unless after.fetch("state").fetch("starts") > before.fetch("state").fetch("starts")
raise "SQLite lost" unless actor.sql_entries == [{"id" => "durable", "value" => "SQLite after runner restart"}]
raise "KV lost" unless actor.kv_get("durable") == {"answer" => 73}
actor.connect do |conn|
  sub = conn.on(:changed)
  conn.emit("changed", "after restart", [7, 3])
  raise "subscription failed" unless sub.poll(timeout: 3) == ["after restart", [7, 3]]
end
puts "After restart: #{JSON.generate(after)}"
puts "Runner restart: identity, state, SQLite, KV and new WebSocket subscription passed"
RUBY
