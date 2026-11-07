module Rivet
  # Context supplied to an actor callback; do not retain it beyond that callback.
  # Hooks may overlap actions. Managed-state writes use a per-actor mutex; other
  # application data needs its own synchronization. Native waits release the GVL
  # but cancellation is cooperative: check {#aborted?} during long work.
  # Native failures raise {Error}; JSON conversion retains Ruby errors.
  class Context
    # Connection associated with this callback, if any.
    # @return [ConnectionContext, nil]
    attr_reader :connection

    # Assemble a callback context; created by the registry.
    # @api private
    # @param native [NativeContext] activation context
    # @param actor [Actor] activation instance
    # @param callback [NativeCallback] reply/cancellation lifetime
    def initialize(native, actor, callback)
      @native = native
      @actor = actor
      @callback = callback
      @connection = callback.connection&.then { |conn| ConnectionContext.new(conn) }
      @metadata = JSON.parse(native.metadata)
    end

    # @return [String] stable actor ID
    def id = @metadata.fetch("id")
    # @return [String] registered actor name
    def name = @metadata.fetch("name")
    # @return [Array<String, Numeric>] engine key segments (Ruby clients use strings)
    def key = @metadata.fetch("key")
    # @return [String] actor region
    def region = @metadata.fetch("region")
    # Check actor cancellation or closure of this callback's reply channel.
    # This does not interrupt Ruby execution or undo external side effects.
    # @return [Boolean]
    def aborted? = @native.aborted? || !@callback.active?

    # Prevent idle sleep while the block runs; always release on block exit.
    # This is not a lock and does not prevent destruction, crashes, shutdown or
    # callback cancellation. Long work must still check {#aborted?}.
    # @yield execute work that must keep this activation awake
    # @yieldreturn [Object] caller result
    # @return [Object] block result
    # @raise [LocalJumpError] no block supplied
    # @raise [Error] callback is no longer active
    def keep_awake
      check_active!
      @native.keep_awake { yield }
    end

    # Reject mutations from a callback whose native reply has closed.
    # @api private
    # @return [nil]
    # @raise [Error] callback is no longer active
    def check_active!
      raise Error, "actor callback is no longer active" unless @callback.active?
    end

    # Read an independent, deeply frozen JSON snapshot of managed state.
    # Prefer SQLite for new durable data; managed state is a compatibility API.
    # @return [Object] frozen snapshot; Hash keys are strings
    def state
      deep_freeze(JSON.parse(@native.state))
    end

    # Replace managed state under the actor's state mutex and request a save.
    # Saving is scheduled, not fsynced on action return. Graceful sleep/shutdown
    # flushes state; abrupt process death may lose recent writes.
    # Ruby assignment syntax returns the original value, not this method's result.
    # @param value [Object] JSON-compatible replacement
    # @return [String] serialized replacement when invoked as a method
    # @raise [Error] callback has expired or native write fails
    # @raise [RangeError] JSON integer exceeds the bridge range
    def state=(value)
      @actor.state_lock.synchronize do
        check_active!
        @native.state = Rivet.dump(value)
      end
    end

    # Atomically read, mutate and replace managed state within this activation.
    # Writes only on normal block completion while the callback is still active;
    # exceptions/nonlocal exits leave the old state. Serialization failure also
    # prevents the write. Keep the block short and I/O-free; the mutex is not
    # reentrant, so do not call state= or update_state inside it.
    # Persistence is scheduled as with {#state=}.
    # @yield [state] mutable JSON snapshot
    # @yieldparam state [Object] current state, with string Hash keys
    # @yieldreturn [Object] arbitrary caller result (not the replacement state)
    # @return [Object] block result
    # @raise [LocalJumpError] no block supplied
    # @raise [Error] callback expires before the write or native write fails
    # @raise [RangeError] mutated state has an out-of-range JSON integer
    def update_state
      check_active!
      @actor.state_lock.synchronize do
        value = JSON.parse(@native.state)
        result = yield value
        check_active!
        @native.state = Rivet.dump(value)
        result
      end
    end

    # Broadcast an event to subscribed clients.
    # @param name [String, Symbol] event name
    # @param args [Array<Object>] positional JSON event arguments
    # @return [nil]
    # @raise [Error] callback has expired or native broadcast fails
    def broadcast(name, *args)
      check_active!
      @native.broadcast(name.to_s, Rivet.dump(args))
    end

    # @return [Array<ConnectionContext>] current server connections
    def connections = @native.connections.map { |conn| ConnectionContext.new(conn) }
    # Request graceful sleep; this does not synchronously stop Ruby execution.
    # @return [nil]
    # @raise [Error] native sleep request fails
    def sleep = @native.sleep
    # Request actor destruction; this does not synchronously stop Ruby execution.
    # @return [nil]
    # @raise [Error] native destroy request fails
    def destroy = @native.destroy
    # @return [SQL] actor's durable SQLite database
    def sql = @sql ||= SQL.new(@native)
    # @return [KV] SQLite-backed compatibility KV store; prefer SQL for new code
    def kv = @kv ||= KV.new(@native)
    # @return [Queue] internal queue, separate from client queue handlers
    def queue = @queue ||= Queue.new(@native)

    # Schedule a one-shot action; it has no cancellation/listing API.
    # @param seconds [Numeric] nonnegative seconds, truncated to milliseconds
    # @param action [String, Symbol] declared action name
    # @param args [Array<Object>] positional JSON-compatible arguments
    # @return [String] schedule ID
    # @raise [ArgumentError] negative delay
    # @raise [Error] callback has expired or native scheduling fails
    def after(seconds, action, *args)
      check_active!
      raise ArgumentError, "delay must be nonnegative" if seconds < 0
      @native.schedule((seconds * 1000).to_i, action.to_s, Rivet.dump(args))
    end

    # Create or update a durable named interval schedule. Reusing a name replaces
    # its action/arguments without resetting an unchanged interval's cadence.
    # Missed intervals are skipped, not replayed. The engine alarm can wake a
    # sleeping actor or recover a lost runner without a client request.
    # @param name [String, Symbol] nonempty actor-scoped schedule name
    # @param seconds [Numeric] finite interval of at least five seconds
    # @param action [String, Symbol] declared action name
    # @param args [Array<Object>] positional JSON-compatible arguments
    # @return [nil]
    # @raise [ArgumentError] invalid interval
    # @raise [Error] callback has expired or native scheduling fails
    def every(name, seconds, action, *args)
      check_active!
      raise ArgumentError, "interval must be finite and at least five seconds" unless seconds.finite? && seconds >= 5
      @native.every(name.to_s, (seconds * 1000).to_i, action.to_s, Rivet.dump(args))
    end

    # Remove a named interval schedule and its history; does not cancel an
    # action already in flight.
    # @param name [String, Symbol] actor-scoped schedule name
    # @return [Boolean] whether a schedule was removed
    # @raise [Error] callback has expired or native cancellation fails
    def cancel_every(name)
      check_active!
      @native.cancel_every(name.to_s)
    end

    private

    # @api private
    # @param value [Object] decoded JSON tree
    # @return [Object] the recursively frozen tree
    def deep_freeze(value)
      case value
      when Hash then value.each { |key, child| key.freeze; deep_freeze(child) }
      when Array then value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
  end

  # Server-side view of one client connection (not a client {Connection}).
  # State reads are mutable copies; only assigning state= writes back. Connection
  # state is connection-scoped, not durable actor data across reconnects. Native
  # failures raise {Error}; coordinate concurrent application use yourself.
  class ConnectionContext
    # Wrap a server connection; obtained from {Context} or connection hooks.
    # @api private
    # @param native [NativeConnection] server connection
    def initialize(native)
      @native = native
    end

    # @return [String] connection ID
    def id = @native.id
    # @return [Object] decoded JSON connection parameters
    def params = JSON.parse(@native.params)
    # @return [Object] mutable copy of JSON connection state
    def state = JSON.parse(@native.state)

    # Replace connection state, without an atomic read/modify/write guarantee.
    # Ruby assignment syntax returns the original value, not this method's result.
    # @param value [Object] JSON-compatible replacement
    # @return [String] serialized replacement when invoked as a method
    # @raise [RangeError] JSON integer exceeds the bridge range
    def state=(value)
      @native.state = Rivet.dump(value)
    end

    # Send an event to this connection only.
    # @param name [String, Symbol] event name
    # @param args [Array<Object>] positional JSON event arguments
    # @return [nil]
    def emit(name, *args)
      @native.send_event(name.to_s, Rivet.dump(args))
    end

    # Disconnect this client, waiting for the native operation.
    # @return [nil]
    def disconnect = @native.disconnect
  end

  # Actor SQLite access, or a transaction-scoped SQL view.
  # Bind nil, booleans (0/1), signed 64-bit integers, floats, UTF-8 text, and
  # binary Strings (Encoding::BINARY) as BLOBs. Results preserve BLOB bytes.
  # Native database/type failures raise {Error}. Give transactions one owner.
  class SQL
    # Wrap a database or transaction; use {Context#sql} or {#transaction}.
    # @api private
    # @param native [NativeContext, NativeTransaction] SQL executor
    def initialize(native)
      @native = native
    end

    # Execute a statement with positional binds.
    # @param statement [String] SQLite SQL
    # @param params [Array<Object>] supported bind values, in placeholder order
    # @return [Hash{String => Object}] "columns" (Array<String>), "rows"
    #   (Array<Array<Object>>), "changes" (Integer), "last_insert_row_id" (Integer or nil)
    # @raise [RangeError] an Integer bind is outside signed 64-bit range
    # @raise [Error] native execution fails or a bind type is unsupported
    def execute(statement, *params)
      params = params.map do |value|
        if value.is_a?(Integer) && !value.between?(-9_223_372_036_854_775_808, 9_223_372_036_854_775_807)
          raise RangeError, "SQL integers must fit in signed 64 bits"
        end
        value.is_a?(String) && value.encoding == Encoding::BINARY ? {blob: value.bytes} : value
      end
      result = JSON.parse(@native.sql(statement, Rivet.dump(params)))
      result.fetch("rows").each do |row|
        row.map! { |value| value.is_a?(Hash) ? value.fetch("blob").pack("C*") : value }
      end
      result
    end

    # Query rows keyed by column name; duplicate names overwrite earlier ones.
    # @param statement [String] SQLite SQL
    # @param params [Array<Object>] supported positional binds as in {#execute}
    # @return [Array<Hash{String => Object}>] rows; empty when no rows returned
    # @raise [RangeError] an Integer bind is outside signed 64-bit range
    # @raise [Error] native query fails
    def query(statement, *params)
      result = execute(statement, *params)
      result.fetch("rows").map { |row| result.fetch("columns").zip(row).to_h }
    end

    # Run a transaction, committing on normal completion and rolling back on
    # exceptions or nonlocal exits. Use only the yielded tx inside the block,
    # not ctx.sql; do not share it across independent operations, retain it after
    # the block, or nest transaction calls on it.
    # @param timeout [Numeric] positive native transaction timeout seconds (default 60)
    # @yield [tx] execute SQL within the transaction
    # @yieldparam tx [SQL] transaction-scoped execute/query interface
    # @yieldreturn [Object] arbitrary caller result
    # @return [Object] block result after successful commit
    # @raise [ArgumentError] no block or nonpositive timeout
    # @raise [Error] native begin, execution, commit or rollback fails
    def transaction(timeout: 60)
      raise ArgumentError, "transaction needs a block" unless block_given?
      raise ArgumentError, "timeout must be positive" unless timeout > 0
      native = @native.begin_sql((timeout * 1000).to_i)
      committed = false
      begin
        value = yield SQL.new(native)
        native.commit
        committed = true
        value
      ensure
        native.rollback unless committed
      end
    end
  end

  # SQLite-backed, JSON-valued actor key/value storage. Retained for compatibility
  # with upstream-deprecated KV; prefer {SQL} for new durable data.
  # Native storage failures raise {Error}.
  class KV
    # Wrap actor storage; use {Context#kv}.
    # @api private
    # @param native [NativeContext] actor context
    def initialize(native)
      @native = native
    end

    # @param key [String, Symbol] key converted with to_s
    # @return [Object, nil] decoded value; nil also represents a missing key
    def [](key)
      @native.kv_get(key.to_s)&.then { |value| JSON.parse(value) }
    end

    # Store a JSON-compatible value.
    # @param key [String, Symbol] key converted with to_s
    # @param value [Object] JSON-compatible value
    # @return [Object] original value
    # @raise [RangeError] JSON integer exceeds the bridge range
    def []=(key, value)
      @native.kv_put(key.to_s, Rivet.dump(value))
      value
    end

    # Delete a key; does not return the previous value.
    # @param key [String, Symbol] key converted with to_s
    # @return [nil]
    def delete(key) = @native.kv_delete(key.to_s)
  end

  # Internal actor queue for manual consumption, not {Actor.queue} handlers.
  # These compatibility queue APIs use Rivet core; prefer actions plus SQLite
  # for new pending-work implementations. Native failures raise {Error}.
  class Queue
    # Wrap the actor's internal queue; use {Context#queue}.
    # @api private
    # @param native [NativeContext] actor context
    def initialize(native)
      @native = native
    end

    # Enqueue a JSON message for manual consumption with {#next}.
    # @param name [String, Symbol] queue name
    # @param body [Object] JSON-compatible message body
    # @return [Integer] message ID
    # @raise [RangeError] JSON integer exceeds the bridge range
    def send(name, body)
      @native.queue_send(name.to_s, Rivet.dump(body))
    end

    # Consume the next matching message using the native queue's semantics.
    # @param names [Array<String, Symbol>] queue-name filter passed to core;
    #   an empty list is forwarded as an empty filter, not rewritten to all queues
    # @param timeout [Numeric] nonnegative wait seconds (default 0), truncated to milliseconds
    # @return [Hash{String => Object}, nil] "id", "name", "body", "created_at",
    #   or nil if no message is returned before timeout
    # @raise [ArgumentError] negative timeout
    def next(*names, timeout: 0)
      raise ArgumentError, "timeout must be nonnegative" if timeout < 0
      @native.queue_next(names.map(&:to_s), (timeout * 1000).to_i)&.then { |message| JSON.parse(message) }
    end
  end
end
