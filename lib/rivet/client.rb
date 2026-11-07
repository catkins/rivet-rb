module Rivet
  HTTPRequest = Struct.new(:method, :url, :headers, :body, keyword_init: true)
  HTTPResponse = Struct.new(:status, :headers, :body, keyword_init: true)

  class Client
    attr_reader :timeout

    def initialize(endpoint = ENV.fetch("RIVET_ENDPOINT", "http://127.0.0.1:6420"),
      token: ENV["RIVET_TOKEN"], namespace: ENV.fetch("RIVET_NAMESPACE", "default"), pool: nil, timeout: 30)
      Rivet.timeout_ms(timeout)
      @timeout = timeout
      @native = NativeClient.new(endpoint, Rivet.dump(token: token, namespace: namespace, pool: pool))
    end

    %i[get_or_create get create].each do |mode|
      define_method(mode) do |name, key = [], timeout: @timeout, **options|
        raise ArgumentError, "actor key must be an array of strings" unless key.is_a?(Array) && key.all? { |part| part.is_a?(String) }
        options[:timeout_ms] = Rivet.timeout_ms(timeout)
        ActorHandle.new(self, @native.handle(mode.to_s, name.to_s, key, Rivet.dump(options)))
      end
    end

    def get_for_id(name, id, **options)
      ActorHandle.new(self, @native.handle("get_for_id", name.to_s, [String(id)], Rivet.dump(options)))
    end
  end

  module Actions
    COERCIONS = %i[
      to_ary to_a to_hash to_str to_int to_i to_f to_c to_r
      to_io to_path to_proc to_regexp deconstruct deconstruct_keys marshal_dump _dump
    ].freeze

    def call(name, *args, timeout: @client.timeout)
      JSON.parse(@native.action(name.to_s, Rivet.dump(args), Rivet.timeout_ms(timeout)))
    end

    def method_missing(name, *args, **kwargs, &block)
      return super if block || COERCIONS.include?(name) || name.to_s.end_with?("=", "?")
      args << kwargs unless kwargs.empty?
      call(name, *args)
    end

    def respond_to_missing?(name, include_private = false)
      (!COERCIONS.include?(name) && !name.to_s.end_with?("=", "?")) || super
    end
  end

  class ActorHandle
    include Actions

    def initialize(client, native)
      @client = client
      @native = native
    end

    def id(timeout: @client.timeout) = @native.resolve(Rivet.timeout_ms(timeout))

    def connect
      connection = Connection.new(@client, @native.connect)
      return connection unless block_given?
      begin
        yield connection
      ensure
        connection.close
      end
    end

    def send_message(name, body, timeout: @client.timeout)
      @native.send_message(name.to_s, Rivet.dump(body), Rivet.timeout_ms(timeout))
    end

    def send_and_wait(name, body, timeout: @client.timeout)
      JSON.parse(@native.send_and_wait(name.to_s, Rivet.dump(body), Rivet.timeout_ms(timeout)))
    end

    def fetch(path = "/", method: "GET", headers: {}, body: nil, timeout: @client.timeout)
      result = JSON.parse(@native.fetch(
        path,
        Rivet.dump(method: method, headers: headers, body: body&.bytes),
        Rivet.timeout_ms(timeout)
      ))
      HTTPResponse.new(
        status: result.fetch("status"),
        headers: result.fetch("headers"),
        body: result.fetch("body").pack("C*")
      )
    end
  end

  class Connection
    include Actions

    def initialize(client, native)
      @client = client
      @native = native
      @subscriptions = []
      @closed = false
    end

    def status = @native.status.to_sym

    def on(name, &block)
      raise Error, "connection is closed" if @closed
      subscription = Subscription.new(@native.subscribe(name.to_s), &block)
      @subscriptions << subscription
      subscription
    end

    def close(timeout: @client.timeout)
      return if @closed
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Rivet.timeout_ms(timeout) / 1000.0
      @closed = true
      begin
        @native.close(Rivet.timeout_ms(timeout))
      ensure
        failure = nil
        @subscriptions.each do |subscription|
          begin
            subscription.unsubscribe(timeout: [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
          rescue StandardError => error
            failure ||= error
          end
        end
        raise failure if failure && !$!
      end
    end
  end

  class Subscription
    def initialize(native, &block)
      @native = native
      @closed = false
      if block
        @thread = Thread.new do
          until @closed
            args = poll(timeout: 0.1)
            block.call(*args) if args && !@closed
          end
        end
      end
    end

    def poll(timeout: 1)
      raise ArgumentError, "timeout must be nonnegative" if timeout < 0
      @native.poll((timeout * 1000).to_i)&.then { |args| JSON.parse(args) }
    end

    def unsubscribe(timeout: 30)
      return if @closed
      @closed = true
      @native.unsubscribe
      if @thread && @thread != Thread.current && !@thread.join(timeout)
        raise TimeoutError, "event listener did not stop before the deadline"
      end
    end
  end
end
