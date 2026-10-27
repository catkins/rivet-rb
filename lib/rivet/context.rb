module Rivet
  class Context
    attr_reader :connection

    def initialize(native, actor, callback)
      @native = native
      @actor = actor
      @callback = callback
      @connection = callback.connection&.then { |conn| ConnectionContext.new(conn) }
      @metadata = JSON.parse(native.metadata)
    end

    def id = @metadata.fetch("id")
    def name = @metadata.fetch("name")
    def key = @metadata.fetch("key")
    def region = @metadata.fetch("region")
    def aborted? = @native.aborted? || !@callback.active?

    def check_active!
      raise Error, "actor callback is no longer active" unless @callback.active?
    end

    def state
      deep_freeze(JSON.parse(@native.state))
    end

    def state=(value)
      check_active!
      @actor.state_lock.synchronize { @native.state = JSON.generate(value) }
    end

    def update_state
      check_active!
      @actor.state_lock.synchronize do
        value = JSON.parse(@native.state)
        result = yield value
        check_active!
        @native.state = JSON.generate(value)
        result
      end
    end

    def broadcast(name, *args)
      check_active!
      @native.broadcast(name.to_s, JSON.generate(args))
    end

    def connections = @native.connections.map { |conn| ConnectionContext.new(conn) }
    def sleep = @native.sleep
    def destroy = @native.destroy
    def sql = @sql ||= SQL.new(@native)
    def kv = @kv ||= KV.new(@native)
    def queue = @queue ||= Queue.new(@native)

    def after(seconds, action, *args)
      check_active!
      raise ArgumentError, "delay must be nonnegative" if seconds < 0
      @native.schedule((seconds * 1000).to_i, action.to_s, JSON.generate(args))
    end

    private

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, child| key.freeze; deep_freeze(child) }
      when Array then value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
  end

  class ConnectionContext
    def initialize(native)
      @native = native
    end

    def id = @native.id
    def params = JSON.parse(@native.params)
    def state = JSON.parse(@native.state)

    def state=(value)
      @native.state = JSON.generate(value)
    end

    def emit(name, *args)
      @native.send_event(name.to_s, JSON.generate(args))
    end

    def disconnect = @native.disconnect
  end

  class SQL
    def initialize(native)
      @native = native
    end

    def execute(statement, *params)
      params = params.map do |value|
        value.is_a?(String) && value.encoding == Encoding::BINARY ? {blob: value.bytes} : value
      end
      result = JSON.parse(@native.sql(statement, JSON.generate(params)))
      result.fetch("rows").each do |row|
        row.map! { |value| value.is_a?(Hash) ? value.fetch("blob").pack("C*") : value }
      end
      result
    end

    def query(statement, *params)
      result = execute(statement, *params)
      result.fetch("rows").map { |row| result.fetch("columns").zip(row).to_h }
    end

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

  class KV
    def initialize(native)
      @native = native
    end

    def [](key)
      @native.kv_get(key.to_s)&.then { |value| JSON.parse(value) }
    end

    def []=(key, value)
      @native.kv_put(key.to_s, JSON.generate(value))
      value
    end

    def delete(key) = @native.kv_delete(key.to_s)
  end

  class Queue
    def initialize(native)
      @native = native
    end

    def send(name, body)
      @native.queue_send(name.to_s, JSON.generate(body))
    end

    def next(*names, timeout: 0)
      raise ArgumentError, "timeout must be nonnegative" if timeout < 0
      @native.queue_next(names.map(&:to_s), (timeout * 1000).to_i)&.then { |message| JSON.parse(message) }
    end
  end
end
