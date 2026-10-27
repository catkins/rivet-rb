module Rivet
  HTTPRequest = Struct.new(:method, :url, :headers, :body, keyword_init: true)
  HTTPResponse = Struct.new(:status, :headers, :body, keyword_init: true)

  class Client
    def initialize(endpoint = ENV.fetch("RIVET_ENDPOINT", "http://127.0.0.1:6420"),
      token: ENV["RIVET_TOKEN"], namespace: ENV.fetch("RIVET_NAMESPACE", "default"), pool: nil)
      @native = NativeClient.new(endpoint, JSON.generate(token: token, namespace: namespace, pool: pool))
    end

    %i[get_or_create get create].each do |mode|
      define_method(mode) do |name, key = [], **options|
        raise ArgumentError, "actor key must be an array of strings" unless key.is_a?(Array) && key.all? { |part| part.is_a?(String) }
        ActorHandle.new(self, @native.handle(mode.to_s, name.to_s, key, JSON.generate(options)))
      end
    end

    def get_for_id(name, id, **options)
      ActorHandle.new(self, @native.handle("get_for_id", name.to_s, [String(id)], JSON.generate(options)))
    end
  end

  module Actions
    def call(name, *args, timeout: 30)
      raise ArgumentError, "timeout must be positive" unless timeout > 0
      JSON.parse(@native.action(name.to_s, JSON.generate(args), (timeout * 1000).to_i))
    rescue RuntimeError => error
      raise Error, error.message
    end

    def method_missing(name, *args, **kwargs, &block)
      return super if block || name.to_s.end_with?("=", "?")
      args << kwargs unless kwargs.empty?
      call(name, *args)
    end

    def respond_to_missing?(name, include_private = false)
      !name.to_s.end_with?("=", "?") || super
    end
  end

  class ActorHandle
    include Actions

    def initialize(client, native)
      @client = client
      @native = native
    end

    def id = @native.resolve

    def connect
      connection = Connection.new(@client, @native.connect)
      return connection unless block_given?
      begin
        yield connection
      ensure
        connection.close
      end
    end

    def send_message(name, body)
      @native.send_message(name.to_s, JSON.generate(body))
    end

    def send_and_wait(name, body, timeout: 30)
      raise ArgumentError, "timeout must be nonnegative" if timeout < 0
      JSON.parse(@native.send_and_wait(name.to_s, JSON.generate(body), (timeout * 1000).to_i))
    end

    def fetch(path = "/", method: "GET", headers: {}, body: nil)
      result = JSON.parse(@native.fetch(path, JSON.generate(method: method, headers: headers, body: body&.bytes)))
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

    def close
      return if @closed
      @closed = true
      @subscriptions.each(&:unsubscribe)
      @native.close
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

    def unsubscribe
      return if @closed
      @closed = true
      @native.unsubscribe
      @thread.join if @thread && @thread != Thread.current
    end
  end
end
