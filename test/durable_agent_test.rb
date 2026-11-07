require_relative "test_helper"
require "net/http"
require "socket"
require "tmpdir"
require "rbconfig"

class DurableAgentTest < Minitest::Test
  def setup
    skip "Set RIVET_ENDPOINT to the local preview engine" unless ENV["RIVET_ENDPOINT"]
    @pool = "ruby-agent-#{SecureRandom.hex(6)}"
    uri = URI("#{ENV.fetch('RIVET_ENDPOINT')}/pools/#{@pool}?namespace=#{ENV.fetch('RIVET_NAMESPACE', 'default')}")
    request = Net::HTTP::Put.new(uri, "Content-Type" => "application/json")
    request["Authorization"] = "Bearer #{ENV['RIVET_TOKEN']}" if ENV["RIVET_TOKEN"]
    request.body = "{}"
    response = Net::HTTP.start(uri.host, uri.port, read_timeout: 5) { |http| http.request(request) }
    assert response.is_a?(Net::HTTPSuccess), response.body
    @directory = Dir.mktmpdir("rivet-durable-agent")
    @log = File.open(File.join(@directory, "runner.log"), "a")
    @requests = []
    @mutex = Mutex.new
    @pauses = {}
    @releases = []
    @peers = []
    @responders = []
    @server = TCPServer.new("127.0.0.1", 0)
    @acceptor = Thread.new do
      loop do
        socket = @server.accept
        @peers << socket
        @responders << Thread.new(socket) { |peer| respond(peer) }
      end
    rescue IOError, Errno::EBADF
      nil
    end
    @client = Rivet::Client.new(pool: @pool, timeout: 5)
    start_runner
  end

  def teardown
    return unless @directory
    @releases.each { |queue| queue << true }
    stop_runner
    @server.close
    @acceptor.join
    @peers.each { |peer| peer.close unless peer.closed? }
    @responders.each { |thread| thread.join(2) }
    @log.close
    warn File.read(@log.path) unless passed?
    FileUtils.remove_entry(@directory)
  end

  def test_committed_steps_deduplication_sleep_and_retry
    actor = agent
    actor.submit("remember", "request-one")
    result = completed(actor, "request-one")
    assert_equal [{"key" => "colour", "value" => "green"}], result.fetch("notes")
    assert_equal %w[system user assistant tool assistant], roles(result)
    assert_equal 1, result.fetch("tools").size
    assert_equal "completed", result.fetch("tools").first.fetch("status")
    assert_equal({"request_id" => "request-one"}, actor.submit("remember", "request-one"))
    assert_raises(Rivet::Error) { actor.submit("different", "request-one") }
    actor.sleep_now
    recovered = actor.snapshot
    assert_equal result.fetch("actor_id"), recovered.fetch("actor_id")
    assert_equal result.fetch("messages"), recovered.fetch("messages")
    assert_equal 2, count("/v1/chat/completions")

    actor.submit("retry", "request-two")
    result = completed(actor, "request-two")
    run = result.fetch("runs").find { |entry| entry.fetch("id") == "request-two" }
    assert_equal 1, run.fetch("attempts")
    assert_equal 4, count("/v1/chat/completions")
  end

  def test_sigkill_during_model_call_repeats_only_the_uncommitted_generation
    entered, release = pause_next("/v1/chat/completions")
    actor = agent
    actor.submit("model", "model-request")
    Timeout.timeout(10) { entered.pop }
    assert_equal %w[system user], roles(actor.snapshot)
    crash_runner
    release << true
    resumed, finish = pause_next("/v1/chat/completions")
    start_runner
    Timeout.timeout(100) { resumed.pop }
    finish << true
    result = completed(actor, "model-request", timeout: 100)
    assert_equal %w[system user assistant], roles(result)
    assert_equal 2, count("/v1/chat/completions")
    assert_equal "finished", result.fetch("messages").last.fetch("message").fetch("content")
  end

  def test_sigkill_replays_safe_tools_but_keeps_completed_tool_results
    entered, release = pause_next("/lookup")
    actor = agent
    actor.submit("publish then lookup", "safe-request")
    Timeout.timeout(10) { entered.pop }
    assert_equal 1, count("/publish")
    assert_equal 1, count("/lookup")
    assert_equal %w[system user assistant tool], roles(actor.snapshot)
    crash_runner
    release << true
    start_runner
    result = completed(actor, "safe-request", timeout: 100)
    assert_equal 1, count("/publish"), "a completed external tool ran twice"
    assert_equal 2, count("/lookup"), "safe interrupted tool was not retried"
    assert_equal 2, count("/v1/chat/completions"), "saved model tool requests were regenerated"
    assert_equal %w[completed completed], result.fetch("tools").map { |tool| tool.fetch("status") }
    assert_equal %w[call_publish call_lookup], result.fetch("messages").filter_map { |entry| entry.fetch("message")["tool_call_id"] }
  end

  def test_sigkill_after_external_side_effect_marks_unknown_without_repeating_it
    entered, release = pause_next("/publish")
    actor = agent
    actor.submit("publish", "unsafe-request")
    Timeout.timeout(10) { entered.pop }
    assert_equal 1, count("/publish"), "external side effect was not reached"
    assert_equal "started", actor.snapshot.fetch("tools").first.fetch("status")
    crash_runner
    release << true
    start_runner
    result = completed(actor, "unsafe-request", timeout: 100)
    assert_equal 1, count("/publish"), "unsafe interrupted tool ran twice"
    assert_equal "interrupted", result.fetch("tools").first.fetch("status")
    message = result.fetch("messages").find { |entry| entry.fetch("message")["tool_call_id"] == "call_publish" }
    assert_includes message.fetch("message").fetch("content"), "outcome unknown"
    assert_equal %w[system user assistant tool assistant], roles(result)
  end

  def test_sigkill_inside_local_tool_transaction_replays_without_partial_commit
    stop_runner
    entered, release = pause_next("/local_checkpoint")
    start_runner(local_barrier: true)
    actor = agent
    actor.submit("remember", "local-request")
    Timeout.timeout(10) { entered.pop }
    crash_runner
    release << true
    start_runner
    result = completed(actor, "local-request", timeout: 100)
    assert_equal [{"key" => "colour", "value" => "green"}], result.fetch("notes")
    assert_equal 1, result.fetch("messages").count { |entry| entry.fetch("message")["tool_call_id"] == "call_remember" }
    assert_equal "completed", result.fetch("tools").first.fetch("status")
    assert_equal 2, count("/v1/chat/completions")
  end

  def test_cancel_is_responsive_durable_and_does_not_resume_after_sigkill
    entered, release = pause_next("/v1/chat/completions")
    actor = agent
    actor.submit("model", "cancelled-request")
    Timeout.timeout(10) { entered.pop }
    actor.cancel("cancelled-request")
    assert_equal "cancelled", actor.snapshot.fetch("runs").first.fetch("status")
    crash_runner
    release << true
    start_runner
    result = eventually(timeout: 100) { actor.snapshot }
    assert_equal "cancelled", result.fetch("runs").first.fetch("status")
    actor.submit("model", "next-request")
    completed(actor, "next-request")
    assert_equal 2, count("/v1/chat/completions"), "cancelled generation resumed"
    assert_equal 0, result.fetch("messages").count { |entry| entry.fetch("message").fetch("role") == "assistant" }
  end

  private

  def agent
    @client.get_or_create(:durable_agent, [SecureRandom.uuid])
  end

  def roles(snapshot)
    snapshot.fetch("messages").map { |entry| entry.fetch("message").fetch("role") }
  end

  def completed(actor, id, timeout: 20)
    eventually(timeout: timeout) do
      snapshot = actor.snapshot
      @last_snapshot = snapshot
      run = snapshot.fetch("runs").find { |entry| entry.fetch("id") == id }
      raise "Agent failed: #{run.inspect}" if run && run.fetch("status") == "failed"
      snapshot if run && run.fetch("status") == "completed"
    end
  end

  def eventually(timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    last_error = nil
    loop do
      begin
        result = yield
        return result if result
      rescue Rivet::Error => error
        raise unless error.message.match?(/deadline|timed out|not_found|unavailable|connection|runner|stopp/i)
        last_error = error.message
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise "Agent did not recover: #{last_error}; #{@last_snapshot.inspect}\n#{File.read(@log.path)}"
      end
      sleep 0.1
    end
  end

  def start_runner(local_barrier: false)
    endpoint = "http://127.0.0.1:#{@server.addr[1]}"
    env = {
      "RIVET_POOL_NAME" => @pool,
      "AGENT_MODEL" => "durable-agent-fake",
      "AGENT_PROVIDER" => "openai",
      "AGENT_PROTOCOL" => "chat_completions",
      "AGENT_API_BASE" => "#{endpoint}/v1",
      "AGENT_TOOL_ENDPOINT" => endpoint,
      "OPENAI_API_KEY" => "fake-local-key",
      "AGENT_TEST_LOCAL_BARRIER" => local_barrier ? "1" : nil,
      "RIVETKIT_ENGINE_SPAWN" => "never"
    }
    @pid = Process.spawn(env, RbConfig.ruby, "-Ilib", "test/fixtures/durable_agent_runner.rb", out: @log, err: [:child, :out])
  end

  def stop_runner
    return unless @pid
    Process.kill("TERM", @pid)
    Timeout.timeout(40) { Process.wait(@pid) }
    @pid = nil
  end

  def crash_runner
    Process.kill("KILL", @pid)
    _, status = Process.wait2(@pid)
    assert_equal Signal.list.fetch("KILL"), status.termsig
    @pid = nil
  end

  def pause_next(path)
    entered, release = ::Queue.new, ::Queue.new
    @mutex.synchronize { @pauses[path] = [entered, release] }
    @releases << release
    [entered, release]
  end

  def count(path)
    @mutex.synchronize { @requests.count { |request| request.fetch(:path) == path } }
  end

  def respond(socket)
    method, target, = socket.gets.split
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = headers["content-length"] ? JSON.parse(socket.read(headers.fetch("content-length").to_i)) : {}
    path = URI(target).path
    pause = @mutex.synchronize do
      @requests << {path: path, method: method, body: body, headers: headers}
      @pauses.delete(path)
    end
    if pause
      pause.first << true
      pause.last.pop
    end
    status, response = if path == "/v1/chat/completions"
      model_response(body)
    else
      [200, {"ok" => true, "value" => "rivet fact"}]
    end
    json = JSON.generate(response)
    socket.write("HTTP/1.1 #{status} #{status == 200 ? 'OK' : 'Service Unavailable'}\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
  rescue IOError, Errno::EPIPE, Errno::ECONNRESET
    nil
  ensure
    socket.close unless socket.closed?
  end

  def model_response(body)
    messages = body.fetch("messages")
    prompt = messages.reverse.find { |message| message.fetch("role") == "user" }.fetch("content")
    if prompt == "retry" && @mutex.synchronize { @requests.count { |request| request[:path] == "/v1/chat/completions" && request[:body]["messages"]&.last&.[]("content") == "retry" } } == 1
      return [503, {error: {message: "retry later", type: "server_error"}}]
    end
    tools = if messages.last.fetch("role") == "user"
      case prompt
      when "remember" then [["remember", {key: "colour", value: "green"}]]
      when "publish" then [["publish", {text: "ship it"}]]
      when "publish then lookup" then [["publish", {text: "saved first"}], ["lookup", {topic: "rivet"}]]
      else []
      end
    else
      []
    end
    message = if tools.empty?
      {role: "assistant", content: "finished"}
    else
      {role: "assistant", content: nil, tool_calls: tools.map do |name, arguments|
        {id: "call_#{name}", type: "function", function: {name: name, arguments: JSON.generate(arguments)}}
      end}
    end
    [200, {id: "response", object: "chat.completion", model: "durable-agent-fake",
      choices: [{index: 0, message: message, finish_reason: tools.empty? ? "stop" : "tool_calls"}],
      usage: {prompt_tokens: 20, completion_tokens: 8, total_tokens: 28}}]
  end
end
