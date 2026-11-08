require_relative "test_helper"

class ActorTest < Minitest::Test
  def test_partial_configuration_preserves_inherited_and_previous_settings
    parent = Class.new(Rivet::Actor)
    parent.configure(sleep_timeout: 123, state_save_interval: Rational(1001, 1000))
    child = Class.new(parent)
    sibling = Class.new(parent)

    assert_equal({sleep_timeout_ms: 9000, state_save_interval_ms: 1001}, child.configure(sleep_timeout: 9))
    assert_equal({sleep_timeout_ms: 9000, state_save_interval_ms: 0}, child.configure(state_save_interval: 0))
    assert_equal({sleep_timeout_ms: 9000, state_save_interval_ms: 0}, child.configure)
    assert_equal({sleep_timeout_ms: 123_000, state_save_interval_ms: 1001}, parent.configure)
    assert_equal({sleep_timeout_ms: 123_000, state_save_interval_ms: 1001}, sibling.configure)
    assert_equal({sleep_timeout_ms: 30_000, state_save_interval_ms: 1000}, Class.new(Rivet::Actor).configure)
  end

  def test_client_rejects_non_string_actor_keys_before_network_io
    client = Rivet::Client.new
    assert_raises(ArgumentError) { client.get_or_create(:counter, "not-an-array") }
    assert_raises(ArgumentError) { client.get(:counter, [123]) }
  end

  def test_json_integer_overflow_is_rejected_before_network_io
    client = Rivet::Client.new
    handle = client.get(:counter)
    [-9_223_372_036_854_775_809, 18_446_744_073_709_551_616].each do |value|
      nested = {"nested" => [0, {"value" => value}]}
      assert_raises(RangeError) { client.get_or_create(:counter, input: nested) }
      assert_raises(RangeError) { handle.call(:echo, nested) }
      assert_raises(RangeError) { handle.send_message(:work, nested) }
    end
  end

  def test_native_conversion_rejects_invalid_values_before_network_io
    handle = Rivet::Client.new.get(:counter)
    custom = Object.new
    def custom.to_json(*) = raise("must not call to_json")
    assert_raises(TypeError) { handle.echo({nested: [custom]}) }
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |value|
      assert_raises(ArgumentError) { handle.echo(value) }
    end
    cycle = []
    cycle << cycle
    assert_raises(ArgumentError) { handle.echo(cycle) }
    assert_raises(EncodingError) { handle.echo(String.new("\xff").force_encoding(Encoding::UTF_8)) }
  end

  def test_ruby_coercions_do_not_call_remote_actions
    handle = Rivet::Client.new.get(:counter)
    assert_equal [handle], Array(handle)
    refute handle.respond_to?(:to_ary)
    assert_nil String.try_convert(handle)
    assert_raises(TypeError) { Integer(handle) }
    assert_raises(TypeError) { Float(handle) }
    assert_raises(NoMethodError) { handle.to_hash }
    assert handle.respond_to?(:increment)
  end

  def test_client_deadlines_must_be_positive_and_finite
    [0, -1, Float::NAN, Float::INFINITY].each do |timeout|
      assert_raises(ArgumentError) { Rivet::Client.new(timeout: timeout) }
    end
  end

  def test_registry_requires_actor_classes
    assert_raises(ArgumentError) { Rivet::Registry.new }
    assert_raises(ArgumentError) { Rivet::Registry.new(counter: Object) }
  end

  def test_sql_rejects_integers_outside_signed_64_bits_before_native_conversion
    sql = Rivet::SQL.new(nil)
    [-9_223_372_036_854_775_809, 9_223_372_036_854_775_808, 18_446_744_073_709_551_616].each do |value|
      assert_raises(RangeError) { sql.execute("SELECT ?", value) }
    end
  end

  def test_missing_handlers_and_negative_timeouts_are_rejected
    actor = Class.new(Rivet::Actor)
    assert_raises(ArgumentError) { actor.action(:read) }
    assert_raises(ArgumentError) { actor.queue(:work) }
    assert_raises(ArgumentError) { actor.configure(sleep_timeout: -1) }
  end
end
