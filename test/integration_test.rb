require_relative "test_helper"

class IntegrationTest < Minitest::Test
  def setup
    skip "Set RIVET_ENDPOINT and run examples/server.rb (or use docker compose)" unless ENV["RIVET_ENDPOINT"]
    @client = Rivet::Client.new(pool: ENV.fetch("RIVET_POOL_NAME", "default"))
    @key = ["ruby-test", SecureRandom.hex(8)]
    @actor = @client.get_or_create(:kitchen_sink, @key, input: {"label" => "hello"})
  end

  def eventually(timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      raise "condition not reached in #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  def test_json_positional_arguments_and_explicit_action_allowlist
    value = {"text" => "日本語 🦀", "nested" => [nil, true, false, 3.25, -7], "empty" => {}}
    assert_equal [value, [1, 2], nil], @actor.echo(value, [1, 2], nil)
    assert_equal [], @actor.echo
    assert_raises(Rivet::Error) { @actor.call(:initialize) }
    assert_raises(Rivet::Error) { @actor.fail }
    assert_equal ["still alive"], @actor.echo("still alive")
  end

  def test_identity_input_and_get_by_key_or_id
    info = @actor.info
    assert_equal @key, info.fetch("key")
    assert_equal "kitchen_sink", info.fetch("name")
    assert_equal({"label" => "hello"}, info.fetch("state").fetch("input"))
    assert_equal 1, info.fetch("state").fetch("created")
    assert_equal info.fetch("id"), @actor.id
    assert_equal info.fetch("id"), @client.get(:kitchen_sink, @key).id
    assert_equal info.fetch("id"), @client.get_for_id(:kitchen_sink, info.fetch("id")).id
    created = @client.create(:counter, @key, input: {"count" => 17})
    assert_equal 20, created.increment(3)
  end

  def test_concurrent_state_changes_do_not_lose_updates
    counter = @client.get_or_create(:counter, @key, input: {"count" => 11})
    counter.id
    workers = 8.times.map { |i| Thread.new { counter.increment(i + 1) } }
    workers.each(&:value)
    assert_equal 47, counter.count
  end

  def test_sql_and_kv_roundtrip_and_delete
    result = @actor.sql_put("a'quoted", "hello\u0000world")
    assert_equal 1, result.fetch("changes")
    @actor.sql_put("b", "second")
    @actor.sql_put("a'quoted", "updated")
    assert_equal [{"id" => "a'quoted", "value" => "updated"}, {"id" => "b", "value" => "second"}], @actor.sql_entries
    payload = {"nested" => [false, nil, 19]}
    assert_equal payload, @actor.kv_put("json", payload)
    assert_equal payload, @actor.kv_get("json")
    @actor.kv_delete("json")
    assert_nil @actor.kv_get("json")
  end

  def test_sql_types_and_commit_or_rollback
    assert_equal [{"integer_value" => -9_007_199_254_740_991, "float_value" => 3.25,
      "null_value" => nil, "bool_value" => 0, "blob_value" => [0, 255, 65]}], @actor.sql_types
    assert_raises(Rivet::Error) { @actor.sql_transaction(true) }
    assert_equal [], @actor.sql_entries
    assert_equal [{"value" => "committed"}], @actor.sql_transaction(false)
    assert_equal [{"id" => "transaction", "value" => "committed"}], @actor.sql_entries
  end

  def test_silo_s3_objects_survive_actor_sleep
    skip "Set S3_ENDPOINT, S3_BUCKET and AWS credentials (provided by Compose)" unless ENV["S3_ENDPOINT"]
    require "aws-sdk-s3"
    body = "Silo object: 日本語 🦀\u0000tail"
    uploaded = @actor.blob_put("hello.txt", body)
    s3 = Aws::S3::Client.new(endpoint: ENV.fetch("S3_ENDPOINT"), region: ENV.fetch("AWS_REGION", "us-east-1"), force_path_style: true)
    assert_equal body.b, s3.get_object(bucket: ENV.fetch("S3_BUCKET"), key: uploaded.fetch("key")).body.read.b
    before = @actor.info.fetch("activation")
    @actor.sleep_now
    eventually { @actor.info.fetch("activation") != before }
    assert_equal body, @actor.blob_get("hello.txt")
  ensure
    s3&.delete_object(bucket: ENV.fetch("S3_BUCKET"), key: uploaded.fetch("key")) if uploaded
  end

  def test_websocket_events_and_connection_state_are_isolated
    @actor.id
    first = @client.get(:kitchen_sink, @key, params: {"user" => "alice"}).connect
    second = @client.get(:kitchen_sink, @key, params: {"user" => "bob"}).connect
    first_sub = first.on(:changed)
    second_sub = second.on(:changed)
    a = first.connection_info
    b = second.connection_info
    assert_equal "alice", a.fetch("state").fetch("user")
    assert_equal "bob", b.fetch("state").fetch("user")
    assert_equal 2, first.connection_info.fetch("state").fetch("calls")
    assert_equal 1, b.fetch("state").fetch("calls")
    refute_equal a.fetch("id"), b.fetch("id")
    assert_includes b.fetch("connections"), a.fetch("id")
    first.emit("changed", {"x" => 4}, [7, 8])
    assert_equal [{"x" => 4}, [7, 8]], first_sub.poll(timeout: 3)
    assert_equal [{"x" => 4}, [7, 8]], second_sub.poll(timeout: 3)
    first.whisper("changed", "private")
    assert_equal ["private"], first_sub.poll(timeout: 3)
    assert_nil second_sub.poll(timeout: 0.1)
    first_sub.unsubscribe
    second.emit("changed", "after unsubscribe")
    assert_equal ["after unsubscribe"], second_sub.poll(timeout: 3)
    assert_nil first_sub.poll(timeout: 0.1)
  ensure
    first&.close
    second&.close
  end

  def test_event_block_and_block_connection_cleanup
    events = ::Queue.new
    @actor.connect do |conn|
      conn.on(:hello) { |value| events << value }
      conn.emit("hello", "from Ruby")
      assert_equal "from Ruby", Timeout.timeout(3) { events.pop }
    end
  end

  def test_queues_and_queue_handler_replies
    id = @actor.enqueue("jobs", {"task" => "first"})
    @actor.enqueue("jobs", {"task" => "second"})
    first = @actor.dequeue("jobs")
    assert_equal id, first.fetch("id")
    assert_equal({"task" => "first"}, first.fetch("body"))
    assert_equal({"task" => "second"}, @actor.dequeue("jobs").fetch("body"))
    assert_nil @actor.dequeue("jobs")
    result = @actor.send_and_wait(:double, {"value" => 13}, timeout: 3)
    assert_equal "completed", result.fetch("status")
    assert_equal 26, result.fetch("response")
  end

  def test_scheduled_actions
    @actor.schedule(0.1, {"alarm" => true})
    assert_equal({"alarm" => true}, eventually { @actor.kv_get("scheduled") })
  end

  def test_raw_http_request_and_binary_response
    response = @actor.fetch("/echo?x=1", method: "POST", body: "\x00\xff\x41".b)
    assert_equal 201, response.status
    assert_equal "POST", response.headers.fetch("x-method")
    assert_equal [65, 255, 0], response.body.bytes
  end

  def test_state_sql_and_kv_survive_sleep_and_wake
    before = @actor.info
    @actor.sql_put("durable", "sqlite")
    @actor.kv_put("durable", {"answer" => 42})
    @actor.sleep_now
    after = eventually do
      info = @actor.info
      info if info.fetch("activation") != before.fetch("activation")
    end
    assert_equal before.fetch("id"), after.fetch("id")
    assert_equal 1, after.fetch("state").fetch("created")
    assert_operator after.fetch("state").fetch("starts"), :>=, 2
    assert_operator after.fetch("state").fetch("sleeps"), :>=, 1
    assert_equal [{"id" => "durable", "value" => "sqlite"}], @actor.sql_entries
    assert_equal({"answer" => 42}, @actor.kv_get("durable"))
  end
end
