require_relative "test_helper"
require "net/http"

class RegistryTest < Minitest::Test
  def test_subclasses_inherit_handlers_and_isolate_overrides
    skip "Set RIVET_ENDPOINT to the local preview engine" unless ENV["RIVET_ENDPOINT"]
    pool = create_pool
    parent = Class.new(Rivet::Actor) do
      state({"base" => 1})
      on_start { |_ctx| @started = ["parent"] }
      action(:read) { |_ctx| label }
      action(:describe) { |ctx| [label, @started, ctx.state] }
      queue(:double) { |_ctx, value| value * 2 }
      def label = "parent"
    end
    child = Class.new(parent) do
      on_start { |_ctx| @started = ["child"] }
      action(:read) { |_ctx| "overridden" }
      action(:child_only) { |_ctx| true }
      def label = "#{super}/child"
    end
    sibling = Class.new(parent) { state({"sibling" => 2}) }
    parent.action(:late) { |_ctx| "parent only" }

    registry = Rivet::Registry.new(parent: parent, child: child, sibling: sibling)
    runner = Thread.new { registry.start(pool: pool) }
    client = Rivet::Client.new(pool: pool)
    key = [SecureRandom.hex(6)]
    base_actor = client.get_or_create(:parent, key)
    child_actor = client.get_or_create(:child, key)
    sibling_actor = client.get_or_create(:sibling, key)

    assert_equal ["parent", ["parent"], {"base" => 1}], base_actor.describe
    assert_equal ["parent/child", ["child"], {"base" => 1}], child_actor.describe
    assert_equal ["parent", ["parent"], {"sibling" => 2}], sibling_actor.describe
    assert_equal "parent", base_actor.read
    assert_equal "overridden", child_actor.read
    assert_equal "parent", sibling_actor.read
    assert child_actor.child_only
    assert_raises(Rivet::Error) { base_actor.child_only }
    assert_raises(Rivet::Error) { sibling_actor.child_only }
    assert_equal({"status" => "completed", "response" => 14}, child_actor.send_and_wait(:double, 7))
    assert_equal "parent only", base_actor.late
    assert_raises(Rivet::Error) { child_actor.late }
  ensure
    registry&.stop
    if runner
      assert runner.join(50), "runner did not shut down"
      runner.value
    end
  end

  def test_activation_isolation_overload_lifecycle_capacity_and_bounded_shutdown
    skip "Set RIVET_ENDPOINT to the local preview engine" unless ENV["RIVET_ENDPOINT"]
    pool = create_pool

    entered, release, connected, result = 4.times.map { ::Queue.new }
    probe = Class.new(Rivet::Actor) do
      action(:echo) { |_ctx, value| value }
      action(:oversized) { |_ctx| 18_446_744_073_709_551_616 }
      action(:to_ary) { |_ctx| ["explicit"] }
      action :block do |ctx|
        entered << true
        release.pop
        begin
          ctx.update_state { |state| state["stale"] = true }
          result << :wrote_stale_state
        rescue Rivet::Error
          result << :cancelled
        end
        nil
      end
      on_connect { |_ctx, _conn| connected << true }
    end
    broken = Class.new(Rivet::Actor) do
      on_start do |_ctx|
        @starts = (@starts || 0) + 1
        raise "first activation fails" if @starts == 1
      end
      action(:starts) { |_ctx| @starts }
    end
    registry = Rivet::Registry.new(probe: probe, broken: broken)
    runner_error = nil
    runner = Thread.new do
      registry.start(pool: pool, workers: 1, lifecycle_workers: 1, shutdown_timeout: 0.3)
    rescue StandardError => error
      runner_error = error
    end
    client = Rivet::Client.new(pool: pool, timeout: 5)
    actor = client.get_or_create(:probe, [SecureRandom.hex(6)])
    assert_equal "ready", actor.echo("ready")
    assert_equal ["explicit"], actor.call(:to_ary)
    assert_output(nil, /RangeError: JSON integers must fit in signed or unsigned 64 bits/) do
      assert_raises(Rivet::Error) { actor.oversized }
    end
    assert_equal "still alive", actor.echo("still alive")
    failed = client.get_or_create(:broken, [SecureRandom.hex(6)])
    assert_output(nil, /RuntimeError: first activation fails/) do
      3.times { assert_raises(Rivet::Error) { failed.starts } }
    end

    blocked = Thread.new do
      actor.call(:block)
    rescue Rivet::Error
      nil
    end
    Timeout.timeout(5) { entered.pop }
    4.times do
      error = assert_raises(Rivet::Error) { actor.echo("must not execute") }
      assert_includes error.message, "overloaded"
    end
    connection = actor.connect
    Timeout.timeout(5) { connected.pop }
    error = assert_raises(Rivet::Error) { connection.echo("must not execute") }
    assert_includes error.message, "overloaded"
    connection.close

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    registry.stop
    assert runner.join(2), "shutdown exceeded its deadline"
    assert_kind_of Rivet::TimeoutError, runner_error
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_raises(Rivet::Error) { registry.start(pool: pool) }
    release << true
    assert_equal :cancelled, Timeout.timeout(5) { result.pop }
  ensure
    release << true if release
    registry&.stop
    runner&.join(2)
    blocked&.join(6)
    connection&.close
  end

  private

  def create_pool
    pool = "ruby-hardening-#{SecureRandom.hex(6)}"
    uri = URI("#{ENV.fetch('RIVET_ENDPOINT')}/pools/#{pool}?namespace=#{ENV.fetch('RIVET_NAMESPACE', 'default')}")
    request = Net::HTTP::Put.new(uri, "Content-Type" => "application/json")
    request["Authorization"] = "Bearer #{ENV['RIVET_TOKEN']}" if ENV["RIVET_TOKEN"]
    request.body = "{}"
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 5) { |http| http.request(request) }
    assert response.is_a?(Net::HTTPSuccess), response.body
    pool
  end
end
