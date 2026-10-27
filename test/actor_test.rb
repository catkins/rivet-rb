require_relative "test_helper"

class ActorTest < Minitest::Test
  def test_inheritance_keeps_parent_actions_and_isolates_child_definitions
    parent = Class.new(Rivet::Actor) { action(:read) { |_ctx| "parent" } }
    child = Class.new(parent) { action(:write) { |_ctx| "child" } }
    assert_equal ["read"], parent.actions.keys
    assert_equal ["read", "write"], child.actions.keys
  end

  def test_client_rejects_non_string_actor_keys_before_network_io
    client = Rivet::Client.new
    assert_raises(ArgumentError) { client.get_or_create(:counter, "not-an-array") }
    assert_raises(ArgumentError) { client.get(:counter, [123]) }
  end

  def test_registry_requires_actor_classes
    assert_raises(ArgumentError) { Rivet::Registry.new }
    assert_raises(ArgumentError) { Rivet::Registry.new(counter: Object) }
  end

  def test_missing_handlers_and_negative_timeouts_are_rejected
    actor = Class.new(Rivet::Actor)
    assert_raises(ArgumentError) { actor.action(:read) }
    assert_raises(ArgumentError) { actor.queue(:work) }
    assert_raises(ArgumentError) { actor.configure(sleep_timeout: -1) }
  end
end
