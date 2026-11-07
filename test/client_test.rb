require_relative "test_helper"
require "socket"

class ClientTest < Minitest::Test
  def test_deadlines_cover_resolution_creation_actions_queues_and_response_bodies
    server = TCPServer.new("127.0.0.1", 0)
    peers = []
    requests = ::Queue.new
    responder = Thread.new do
      loop do
        socket = server.accept
        peers << socket
        request = socket.gets
        while (line = socket.gets) && line != "\r\n"
        end
        requests << request
        body = request.include?("/metadata") ? "{}" : "{"
        length = body == "{}" ? 2 : 100
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{length}\r\nConnection: close\r\n\r\n#{body}")
        socket.close if length == 2
      end
    rescue IOError, Errno::EBADF
      nil
    end
    client = Rivet::Client.new("http://127.0.0.1:#{server.addr[1]}", timeout: 0.05)
    handle = client.get(:counter)
    resolved = client.get_for_id(:counter, "test-actor")
    operations = [
      -> { handle.id },
      -> { client.create(:counter) },
      -> { resolved.call(:read) },
      -> { resolved.send_message(:work, {}) },
      -> { resolved.send_and_wait(:work, {}) },
      -> { resolved.fetch("/body") }
    ]
    operations.each do |operation|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Rivet::TimeoutError, &operation)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    end
    received = requests.size.times.map { requests.pop }
    assert received.any? { |request| request.include?("/body") }, received.inspect
  ensure
    server&.close
    responder&.join
    peers&.each { |socket| socket.close unless socket.closed? }
  end
end
