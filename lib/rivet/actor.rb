module Rivet
  # Base class for hosted actors; declare actions and hooks on a subclass.
  # Blocks execute with the activation's actor instance as self. Instance variables
  # are ephemeral; use SQLite or managed state for durable data. Subclasses inherit
  # copies of DSL registrations. Only declared actions are remotely callable.
  #
  # Actions, queue handlers and HTTP handlers share a per-instance mutex. Hooks
  # can overlap them; synchronize shared instance variables yourself. Avoid
  # synchronous self-calls and cyclic actor calls. State and callback results use
  # JSON; see {Rivet} for integer limits, cancellation and Ractor restrictions.
  class Actor
    # Supported lifecycle and connection registration names.
    # @api private
    HOOKS = %i[
      on_create on_start on_sleep on_destroy on_before_connect
      on_connect on_disconnect on_subscribe create_conn_state on_fetch run
    ].freeze

    class << self
      # Copy DSL registrations to a subclass.
      # @api private
      # @param child [Class<Actor>] new subclass
      # @return [Proc, nil] inherited state initializer
      def inherited(child)
        child.instance_variable_set(:@actions, actions.dup)
        child.instance_variable_set(:@queues, queues.dup)
        child.instance_variable_set(:@hooks, hooks.dup)
        child.instance_variable_set(:@options, options.dup)
        child.instance_variable_set(:@initializer, initializer)
      end

      # @api private
      # @return [Hash{String => Proc}] action registrations
      def actions = @actions ||= {}
      # @api private
      # @return [Hash{String => Proc}] queue registrations
      def queues = @queues ||= {}
      # @api private
      # @return [Hash{String => Proc}] hook registrations
      def hooks = @hooks ||= {}
      # @api private
      # @return [Hash{Symbol => Integer}] native actor settings
      def options = @options ||= {}
      # @api private
      # @return [Proc, nil] state factory
      def initializer = @initializer

      # Set the initial managed state for newly created actors, not each wake.
      # A block takes precedence over value; constant values are JSON-copied.
      # Managed state is retained for compatibility; prefer SQLite for new data.
      # @param value [Object] JSON-compatible default (defaults to {})
      # @yield [ctx, input] compute the initial JSON-compatible state
      # @yieldparam ctx [Context] actor context
      # @yieldparam input [Object, nil] creation input, nil when absent
      # @yieldreturn [Object] initial state
      # @return [Proc] registered initializer
      def state(value = {}, &block)
        @initializer = block || ->(_ctx, _input) { JSON.parse(Rivet.dump(value)) }
      end

      # Register or replace a remotely callable action.
      # @param name [String, Symbol] nonempty action name
      # @yield [ctx, *args] handle a client call
      # @yieldparam ctx [Context] actor context
      # @yieldparam args [Array<Object>] positional JSON arguments
      # @yieldreturn [Object] JSON-compatible action result
      # @return [Proc] registered handler
      # @raise [ArgumentError] no block or empty name
      def action(name, &block)
        raise ArgumentError, "an action needs a block" unless block
        raise ArgumentError, "action name must not be empty" if name.to_s.empty?
        actions[name.to_s] = block
      end

      # Register a client-sent queue handler (not the internal {Context#queue}).
      # @param name [String, Symbol] handler name
      # @yield [ctx, body] handle send_message or send_and_wait
      # @yieldparam ctx [Context] actor context
      # @yieldparam body [Object] JSON message body
      # @yieldreturn [Object] JSON-compatible reply
      # @return [Proc] registered handler
      # @raise [ArgumentError] no block
      def queue(name, &block)
        raise ArgumentError, "a queue handler needs a block" unless block
        queues[name.to_s] = block
      end

      # Configure idle sleep and scheduled managed-state saves in seconds.
      # Returning from an action is not an fsync guarantee. Graceful sleep and
      # shutdown flush state; abrupt process death may lose unsaved changes.
      # @param sleep_timeout [Numeric] nonnegative idle seconds (default 30)
      # @param state_save_interval [Numeric] nonnegative save seconds (default 1)
      # @return [Hash{Symbol => Integer}] merged settings in milliseconds
      # @raise [ArgumentError] either duration is negative
      def configure(sleep_timeout: 30, state_save_interval: 1)
        raise ArgumentError, "timeouts must be nonnegative" if sleep_timeout < 0 || state_save_interval < 0
        options.merge!(
          sleep_timeout_ms: (sleep_timeout * 1000).to_i,
          state_save_interval_ms: (state_save_interval * 1000).to_i
        )
      end

      # @!method run(&block)
      #   Register activation-scoped background work, started after on_start.
      #   Runs independently of action serialization, once per activation. It
      #   does not keep an idle actor awake; use Context#keep_awake around work.
      #   Cooperate with Context#aborted? and do not retain the context after
      #   returning. Unhandled failures stop the activation with an error.
      #   @yield [ctx]
      #   @yieldparam ctx [Context] context valid for this run hook's lifetime
      #   @yieldreturn [Object] ignored
      #   @return [Proc] registered hook
      #   @raise [ArgumentError] no block
      # @!method on_create(&block)
      #   Register a hook run once when the actor is first created.
      #   @yield [ctx]
      #   @yieldparam ctx [Context] actor context
      #   @yieldreturn [Object] ignored
      #   @return [Proc] registered hook
      #   @raise [ArgumentError] no block
      # @!method on_start(&block)
      #   Register a hook run on every activation, including the first.
      #   @yield [ctx]
      #   @yieldparam ctx [Context] actor context
      #   @yieldreturn [Object] ignored
      #   @return [Proc] registered hook
      #   @raise [ArgumentError] no block
      # @!method on_sleep(&block)
      #   Register cleanup before sleep; state updates are permitted here.
      #   @yield [ctx]
      #   @yieldparam ctx [Context] actor context
      #   @yieldreturn [Object] ignored
      #   @return [Proc] registered hook
      #   @raise [ArgumentError] no block
      # @!method on_destroy(&block)
      #   Register cleanup when the actor is destroyed.
      #   @yield [ctx]
      #   @yieldparam ctx [Context] actor context
      #   @yieldreturn [Object] ignored
      #   @return [Proc] registered hook
      #   @raise [ArgumentError] no block
      # @!method on_before_connect(&block)
      #   Register validation before a connection is accepted; raise to reject.
      #   @yield [ctx, params]
      #   @yieldparam ctx [Context] actor context
      #   @yieldparam params [Object] JSON connection parameters
      #   @yieldreturn [Object] ignored
      #   @return [Proc] registered hook
      #   @raise [ArgumentError] no block
      # @!method create_conn_state(&block)
      #   Register initial connection-state creation; defaults to {} if absent.
      #   @yield [ctx, params]
      #   @yieldparam ctx [Context] actor context
      #   @yieldparam params [Object] JSON connection parameters
      #   @yieldreturn [Object] JSON-compatible connection state
      #   @return [Proc] registered hook
      #   @raise [ArgumentError] no block
      # @!method on_connect(&block)
      #   Register a hook after connection establishment.
      #   @yield [ctx, conn]
      #   @yieldparam ctx [Context] actor context
      #   @yieldparam conn [ConnectionContext] server connection
      #   @yieldreturn [Object] ignored
      #   @return [Proc] registered hook
      #   @raise [ArgumentError] no block
      # @!method on_disconnect(&block)
      #   Register connection cleanup.
      #   @yield [ctx, conn]
      #   @yieldparam ctx [Context] actor context
      #   @yieldparam conn [ConnectionContext] disconnected connection
      #   @yieldreturn [Object] ignored
      #   @return [Proc] registered hook
      #   @raise [ArgumentError] no block
      # @!method on_subscribe(&block)
      #   Register a hook for event subscription.
      #   @yield [ctx, conn, event]
      #   @yieldparam ctx [Context] actor context
      #   @yieldparam conn [ConnectionContext] subscribing connection
      #   @yieldparam event [String] event name
      #   @yieldreturn [Object] ignored
      #   @return [Proc] registered hook
      #   @raise [ArgumentError] no block
      # @!method on_fetch(&block)
      #   Register buffered HTTP handling; missing handlers return HTTP 404.
      #   This is a Rack-shaped triple, not a Rack adapter or streaming API.
      #   @yield [ctx, request]
      #   @yieldparam ctx [Context] actor context
      #   @yieldparam request [HTTPRequest] fully buffered request
      #   @yieldreturn [Array(Integer, Hash{String => String}, Enumerable<String>)] status, headers, body chunks
      #   @return [Proc] registered handler
      #   @raise [ArgumentError] no block
      HOOKS.each do |hook|
        define_method(hook) do |&block|
          raise ArgumentError, "#{hook} needs a block" unless block
          hooks[hook.to_s] = block
        end
      end
    end

    # Per-activation state mutex used by Context.
    # @api private
    # @return [Mutex]
    attr_reader :state_lock, :action_lock

    # Allocate activation-local locks; the registry constructs actor instances.
    # @return [Actor] a new activation instance
    def initialize
      @state_lock = Mutex.new
      @action_lock = Mutex.new
    end

    # Invoke a native callback through the registered DSL block.
    # @api private
    # @param kind [String] callback kind
    # @param ctx [Context] callback context
    # @param data [Object] decoded callback data
    # @return [Object] callback result
    def dispatch(kind, ctx, data)
      case kind
      when "create_state"
        handler = self.class.initializer
        handler ? instance_exec(ctx, data, &handler) : {}
      when "action", "queue"
        handlers = kind == "action" ? self.class.actions : self.class.queues
        args = kind == "action" ? data.fetch("args") : [data["body"]]
        action_lock.synchronize do
          ctx.check_active!
          instance_exec(ctx, *args, &handlers.fetch(data.fetch("name")))
        end
      when "on_fetch"
        handler = self.class.hooks[kind]
        return {status: 404, headers: {}, body: []} unless handler
        request = HTTPRequest.new(
          method: data.fetch("method"),
          url: data.fetch("url"),
          headers: data.fetch("headers"),
          body: data.fetch("body").pack("C*")
        )
        status, headers, body = action_lock.synchronize do
          ctx.check_active!
          instance_exec(ctx, request, &handler)
        end
        {status: status, headers: headers, body: body.to_a.join.bytes}
      else
        handler = self.class.hooks[kind]
        return(kind == "create_conn_state" ? {} : nil) unless handler
        args = case kind
        when "on_connect", "on_disconnect" then [ctx, ctx.connection]
        when "on_subscribe" then [ctx, ctx.connection, data]
        when "on_before_connect", "create_conn_state" then [ctx, data]
        else [ctx]
        end
        instance_exec(*args, &handler)
      end
    end
  end
end
