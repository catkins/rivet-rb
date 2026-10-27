module Rivet
  class Actor
    HOOKS = %i[
      on_create on_start on_sleep on_destroy on_before_connect
      on_connect on_disconnect on_subscribe create_conn_state on_fetch
    ].freeze

    class << self
      def inherited(child)
        child.instance_variable_set(:@actions, actions.dup)
        child.instance_variable_set(:@queues, queues.dup)
        child.instance_variable_set(:@hooks, hooks.dup)
        child.instance_variable_set(:@options, options.dup)
        child.instance_variable_set(:@initializer, initializer)
      end

      def actions = @actions ||= {}
      def queues = @queues ||= {}
      def hooks = @hooks ||= {}
      def options = @options ||= {}
      def initializer = @initializer

      def state(value = {}, &block)
        @initializer = block || ->(_ctx, _input) { JSON.parse(JSON.generate(value)) }
      end

      def action(name, &block)
        raise ArgumentError, "an action needs a block" unless block
        raise ArgumentError, "action name must not be empty" if name.to_s.empty?
        actions[name.to_s] = block
      end

      def queue(name, &block)
        raise ArgumentError, "a queue handler needs a block" unless block
        queues[name.to_s] = block
      end

      def configure(sleep_timeout: 30, state_save_interval: 1)
        raise ArgumentError, "timeouts must be nonnegative" if sleep_timeout < 0 || state_save_interval < 0
        options.merge!(
          sleep_timeout_ms: (sleep_timeout * 1000).to_i,
          state_save_interval_ms: (state_save_interval * 1000).to_i
        )
      end

      HOOKS.each do |hook|
        define_method(hook) do |&block|
          raise ArgumentError, "#{hook} needs a block" unless block
          hooks[hook.to_s] = block
        end
      end
    end

    attr_reader :state_lock, :action_lock

    def initialize
      @state_lock = Mutex.new
      @action_lock = Mutex.new
    end

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
        status, headers, body = action_lock.synchronize { instance_exec(ctx, request, &handler) }
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
