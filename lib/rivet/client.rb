module Rivet
  # Buffered incoming HTTP request passed to {Actor.on_fetch}.
  # Keyword-initialized Struct; omitted members default to nil. Native requests
  # populate every member. Members are writable without type validation.
  # @!attribute [r] method
  #   @return [String] HTTP method
  # @!attribute [w] method
  #   @param value [String] HTTP method
  #   @return [String] assigned value
  # @!attribute [r] url
  #   @return [String] request URL
  # @!attribute [w] url
  #   @param value [String] request URL
  #   @return [String] assigned value
  # @!attribute [r] headers
  #   @return [Hash{String => String}] request headers
  # @!attribute [w] headers
  #   @param value [Hash{String => String}] request headers
  #   @return [Hash{String => String}] assigned value
  # @!attribute [r] body
  #   @return [String] binary request bytes, not a stream
  # @!attribute [w] body
  #   @param value [String] binary request bytes
  #   @return [String] assigned value
  HTTPRequest = Struct.new(:method, :url, :headers, :body, keyword_init: true)
  # Buffered response returned by {ActorHandle#fetch}.
  # Keyword-initialized Struct; omitted members default to nil. Native responses
  # populate every member. Members are writable without type validation.
  # @!attribute [r] status
  #   @return [Integer] HTTP status code
  # @!attribute [w] status
  #   @param value [Integer] HTTP status code
  #   @return [Integer] assigned value
  # @!attribute [r] headers
  #   @return [Hash{String => String}] response headers
  # @!attribute [w] headers
  #   @param value [Hash{String => String}] response headers
  #   @return [Hash{String => String}] assigned value
  # @!attribute [r] body
  #   @return [String] binary response bytes, not a stream
  # @!attribute [w] body
  #   @param value [String] binary response bytes
  #   @return [String] assigned value
  HTTPResponse = Struct.new(:status, :headers, :body, keyword_init: true)

  # Factory for HTTP actor handles and WebSocket connections.
  # Clients and handles support ordinary Ruby threads in the main Ractor only.
  # Native deadlines cover discovery, requests and response bodies, not remote
  # rollback. See {Rivet} for serialization and cancellation restrictions.
  class Client
    # Default total native-operation deadline, in seconds.
    # @return [Numeric]
    attr_reader :timeout

    # Build a client without resolving an actor.
    # @param endpoint [String] engine URL; defaults to RIVET_ENDPOINT or http://127.0.0.1:6420
    # @param token [String, nil] auth token; defaults to RIVET_TOKEN
    # @param namespace [String] defaults to RIVET_NAMESPACE or "default"
    # @param pool [String, nil] default creation pool; nil uses the SDK default
    # @param timeout [Numeric] positive finite default seconds (default 30)
    # @raise [ArgumentError] invalid timeout
    # @raise [Error] invalid native client configuration
    # @return [Client]
    def initialize(endpoint = ENV.fetch("RIVET_ENDPOINT", "http://127.0.0.1:6420"),
      token: ENV["RIVET_TOKEN"], namespace: ENV.fetch("RIVET_NAMESPACE", "default"), pool: nil, timeout: 30)
      Rivet.timeout_ms(timeout)
      @timeout = timeout
      @native = NativeClient.new(endpoint, Rivet.dump(token: token, namespace: namespace, pool: pool))
    end

    # @!method get_or_create(name, key = [], timeout: @timeout, **options)
    #   Build a lazy handle that finds or creates an actor on first operation.
    #   Resolve a shared creating handle with #id before concurrent fan-out;
    #   independent cold creating handles can still race in the engine.
    #   @param name [String, Symbol] registered actor name
    #   @param key [Array<String>] actor key segments (default [])
    #   @param timeout [Numeric] positive finite seconds; defaults to client timeout (validated here, resolution uses each operation's deadline)
    #   @param options [Hash] native handle options
    #   @option options [Object] :params connection parameters
    #   @option options [Object] :input input used only on creation
    #   @option options [String] :pool creation pool override
    #   @option options [String] :region creation region
    #   @return [ActorHandle] unresolved handle
    #   @raise [ArgumentError] key is not an Array of Strings or timeout is invalid
    #   @raise [Error] native handle construction fails
    # @!method get(name, key = [], timeout: @timeout, **options)
    #   Build a lazy handle for an existing keyed actor; does not create one.
    #   @param name [String, Symbol] registered actor name
    #   @param key [Array<String>] actor key segments (default [])
    #   @param timeout [Numeric] positive finite seconds; defaults to client timeout (validated here, resolution uses each operation's deadline)
    #   @param options [Hash] native handle options; only params is used by get
    #   @option options [Object] :params connection parameters
    #   @return [ActorHandle] unresolved handle; missing actor errors occur on use
    #   @raise [ArgumentError] key is not an Array of Strings or timeout is invalid
    #   @raise [Error] native handle construction fails
    # @!method create(name, key = [], timeout: @timeout, **options)
    #   Eagerly create an actor within the total native-operation deadline.
    #   @param name [String, Symbol] registered actor name
    #   @param key [Array<String>] actor key segments (default [])
    #   @param timeout [Numeric] positive finite seconds; defaults to client timeout
    #   @param options [Hash] native creation options
    #   @option options [Object] :params connection parameters
    #   @option options [Object] :input creation input
    #   @option options [String] :pool creation pool override
    #   @option options [String] :region creation region
    #   @return [ActorHandle] handle for the created actor
    #   @raise [ArgumentError] key is not an Array of Strings or timeout is invalid
    #   @raise [TimeoutError] creation deadline expired; the actor may exist
    #   @raise [Error] native creation fails
    %i[get_or_create get create].each do |mode|
      define_method(mode) do |name, key = [], timeout: @timeout, **options|
        raise ArgumentError, "actor key must be an array of strings" unless key.is_a?(Array) && key.all? { |part| part.is_a?(String) }
        options[:timeout_ms] = Rivet.timeout_ms(timeout)
        ActorHandle.new(self, @native.handle(mode.to_s, name.to_s, key, Rivet.dump(options)))
      end
    end

    # Build a handle for a known actor ID without key discovery.
    # @param name [String, Symbol] registered actor name
    # @param id [#to_s] ID converted with String(id)
    # @param options [Hash] native handle options; only params is used
    # @option options [Object] :params connection parameters
    # @return [ActorHandle]
    # @raise [Error] native handle construction fails
    def get_for_id(name, id, **options)
      ActorHandle.new(self, @native.handle("get_for_id", name.to_s, [String(id)], Rivet.dump(options)))
    end
  end

  # Shared remote-action API for {ActorHandle} (HTTP) and {Connection} (WebSocket).
  # Unknown Ruby methods become action calls unless a block is supplied, the name
  # ends in = or ?, or it is a reserved coercion/pattern-matching protocol name.
  # Keyword arguments become a final positional JSON object, including timeout:;
  # use {#call} for operation deadlines and names colliding with Ruby methods.
  # respond_to? is optimistic, not an action-existence check.
  # @!method method_missing(name, *args, **kwargs, &block)
  #   Forward eligible unknown methods to {#call}; others use Ruby's fallback.
  #   @param name [Symbol] method/action name
  #   @param args [Array<Object>] positional JSON arguments
  #   @param kwargs [Hash] appended as the last positional argument if nonempty
  #   @param block [Proc, nil] blocks prevent remote dispatch
  #   @return [Object] decoded action result
  #   @raise [NoMethodError] blocked or reserved missing method
  #   @raise [Error] remote action fails
  #   @raise [TimeoutError] client deadline expires; action may have run
  module Actions
    # Names that must never implicitly initiate remote calls.
    # @api private
    COERCIONS = %i[
      to_ary to_a to_hash to_str to_int to_i to_f to_c to_r
      to_io to_path to_proc to_regexp deconstruct deconstruct_keys marshal_dump _dump
    ].freeze

    # Invoke an explicitly named action, bypassing Ruby name collisions.
    # @param name [String, Symbol] action name
    # @param args [Array<Object>] positional JSON-compatible arguments
    # @param timeout [Numeric] positive finite seconds; defaults to client timeout
    # @return [Object] decoded JSON result
    # @raise [ArgumentError] invalid timeout
    # @raise [RangeError] a serialized integer is outside the JSON bridge range
    # @raise [TimeoutError] deadline expires; the action may have run
    # @raise [Error] discovery or action fails
    def call(name, *args, timeout: @client.timeout)
      JSON.parse(@native.action(name.to_s, Rivet.dump(args), Rivet.timeout_ms(timeout)))
    end

    # Implement the convenience dispatch described on {Actions}.
    # @param name [Symbol] missing method name
    # @param args [Array<Object>] positional action arguments
    # @param kwargs [Hash] final JSON object argument
    # @param block [Proc, nil] when present, use Ruby's missing-method fallback
    # @return [Object] action result
    # @raise [NoMethodError] method cannot be implicitly dispatched
    # @see #call
    def method_missing(name, *args, **kwargs, &block)
      return super if block || COERCIONS.include?(name) || name.to_s.end_with?("=", "?")
      args << kwargs unless kwargs.empty?
      call(name, *args)
    end

    # Report eligible dynamic action names without contacting the server.
    # @param name [Symbol] candidate Ruby method
    # @param include_private [Boolean] passed to Ruby's fallback (default false)
    # @return [Boolean] whether the name could be dispatched, not whether it exists
    def respond_to_missing?(name, include_private = false)
      (!COERCIONS.include?(name) && !name.to_s.end_with?("=", "?")) || super
    end
  end

  # Reusable actor reference. Calls use stateless HTTP unless {#connect} is used.
  # A resolved actor ID is cached natively. Ordinary threads may share a handle;
  # resolve creating handles before fan-out to avoid concurrent cold creation.
  class ActorHandle
    include Actions

    # Wrap a native handle; obtain handles from {Client} instead.
    # @api private
    # @param client [Client] owner
    # @param native [NativeHandle] native transport
    def initialize(client, native)
      @client = client
      @native = native
    end

    # Resolve and cache this handle's actor ID (may create a lazy actor).
    # @param timeout [Numeric] positive finite seconds; defaults to client timeout
    # @return [String] actor ID
    # @raise [ArgumentError] invalid timeout
    # @raise [TimeoutError] deadline expires; creation may have happened
    # @raise [Error] resolution fails
    def id(timeout: @client.timeout) = @native.resolve(Rivet.timeout_ms(timeout))

    # Start a WebSocket connection asynchronously, without waiting for readiness.
    # The block form always closes it in ensure, using the client's timeout.
    # Give the connection one owner or synchronize access; do not race on/close.
    # @yield [connection] optional scoped use
    # @yieldparam connection [Connection] newly started connection
    # @yieldreturn [Object] caller result
    # @return [Connection] without a block
    # @return [Object] block result with a block
    # @raise [Error] native connection/cleanup fails
    # @raise [TimeoutError] cleanup deadline expires
    def connect
      connection = Connection.new(@client, @native.connect)
      return connection unless block_given?
      begin
        yield connection
      ensure
        connection.close
      end
    end

    # Send to a declared {Actor.queue} handler, without waiting for its reply.
    # This does not enqueue for {Context#queue} manual consumption.
    # @param name [String, Symbol] handler name
    # @param body [Object] JSON-compatible body
    # @param timeout [Numeric] positive finite seconds; defaults to client timeout
    # @return [nil]
    # @raise [ArgumentError] invalid timeout
    # @raise [TimeoutError] deadline expires; message may have been sent
    # @raise [Error] native send fails
    def send_message(name, body, timeout: @client.timeout)
      @native.send_message(name.to_s, Rivet.dump(body), Rivet.timeout_ms(timeout))
    end

    # Send to a declared queue handler and wait for its result.
    # Zero is not a fire-and-forget timeout; use {#send_message} instead.
    # @param name [String, Symbol] handler name
    # @param body [Object] JSON-compatible body
    # @param timeout [Numeric] positive finite seconds; defaults to client timeout
    # @return [Hash{String => Object}] "status" (lowercase SDK status) and "response"
    # @raise [ArgumentError] invalid timeout
    # @raise [TimeoutError] deadline expires; handler may have run
    # @raise [Error] native send/handler fails
    def send_and_wait(name, body, timeout: @client.timeout)
      JSON.parse(@native.send_and_wait(name.to_s, Rivet.dump(body), Rivet.timeout_ms(timeout)))
    end

    # Request the actor's raw HTTP handler; buffers both bodies in memory.
    # @param path [String] actor-relative path (default "/")
    # @param method [String] HTTP method (default "GET")
    # @param headers [Hash{String => String}] request headers (default {})
    # @param body [String, nil] request bytes (default nil)
    # @param timeout [Numeric] positive finite total seconds; defaults to client timeout
    # @return [HTTPResponse] response, including non-success HTTP statuses
    # @raise [ArgumentError] invalid timeout
    # @raise [TimeoutError] deadline expires, including while reading response body
    # @raise [Error] native request fails
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

  # Client WebSocket connection supporting actions and event subscriptions.
  # Coordinate ownership yourself; do not race subscription creation with close.
  class Connection
    include Actions

    # Wrap a native connection; use {ActorHandle#connect}.
    # @api private
    # @param client [Client] owner
    # @param native [NativeClientConnection] transport
    def initialize(client, native)
      @client = client
      @native = native
      @subscriptions = []
      @closed = false
    end

    # @return [Symbol] lowercase native SDK connection status
    def status = @native.status.to_sym

    # Subscribe to positional event arguments; an Array argument stays nested.
    # With a block, a Ruby listener thread consumes events. Without one, use poll.
    # Do not combine the two consumers. Listener blocks must cooperate with
    # shutdown and synchronize any application data shared with other threads.
    # @param name [String, Symbol] event name
    # @yield [*args] optional listener called on a Ruby thread
    # @yieldparam args [Array<Object>] decoded positional event arguments
    # @yieldreturn [Object] ignored
    # @return [Subscription]
    # @raise [Error] connection has been closed
    def on(name, &block)
      raise Error, "connection is closed" if @closed
      subscription = Subscription.new(@native.subscribe(name.to_s), &block)
      @subscriptions << subscription
      subscription
    end

    # Close transport and unsubscribe all listeners, sharing one total deadline.
    # Marks the wrapper closed before waiting; subsequent calls are no-ops even
    # after a failed close. A timeout never kills a running listener block.
    # @param timeout [Numeric] positive finite seconds; defaults to client timeout
    # @return [nil]
    # @raise [ArgumentError] invalid timeout on the first close
    # @raise [TimeoutError] transport or listener shutdown exceeds the deadline
    # @raise [Error] native close fails
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

  # An event receiver owned by one connection. Use a listener block or manual
  # polling, not both: they compete for events. Unsubscribe when finished.
  class Subscription
    # Wrap a native subscription; use {Connection#on}.
    # @api private
    # @param native [NativeSubscription] event receiver
    # @yield [*args] optional event listener on a Ruby thread
    # @yieldparam args [Array<Object>] event arguments
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

    # Wait for one event without invoking the listener.
    # @param timeout [Numeric] nonnegative wait seconds (default 1); zero polls
    # @return [Array<Object>, nil] positional event arguments, or nil if none arrives
    # @raise [ArgumentError] negative timeout
    def poll(timeout: 1)
      raise ArgumentError, "timeout must be nonnegative" if timeout < 0
      @native.poll((timeout * 1000).to_i)&.then { |args| JSON.parse(args) }
    end

    # Unsubscribe and join the listener, unless called by that listener itself.
    # Does not interrupt an executing block. Repeated calls are no-ops, including
    # after a join timeout; they do not wait again for an outstanding listener.
    # @param timeout [Numeric, nil] join seconds (default 30); nil waits indefinitely,
    #   zero does not wait
    # @return [nil]
    # @raise [TimeoutError] listener did not finish before the join deadline
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
