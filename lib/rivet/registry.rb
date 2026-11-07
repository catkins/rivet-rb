module Rivet
  # Hosts named actor subclasses on Ruby-created callback threads in the main
  # Ractor. Each activation has a separate Ruby instance. Signal handling belongs
  # to the application: arrange for INT/TERM handlers to call {#stop}.
  class Registry
    # Register actor definitions; a name is the client-visible actor type.
    # @param actors [Hash{Symbol => Class<Actor>}] nonempty keyword registrations
    # @return [Registry]
    # @raise [ArgumentError] no actors or any value is not an Actor subclass
    def initialize(**actors)
      raise ArgumentError, "register at least one actor" if actors.empty?
      actors.each_value do |actor|
        raise ArgumentError, "actors must inherit Rivet::Actor" unless actor.is_a?(Class) && actor < Actor
      end
      @actors = actors.transform_keys(&:to_s)
      @instances = {}
      @workers = {}
    end

    # Start the native runner and block while dispatching callbacks.
    # Start once at a time; another Ruby thread may call {#stop}. Work, lifecycle
    # and background run callbacks have separate live-thread limits. Background
    # hooks share the work channel; work and lifecycle channels each hold at
    # most 64 pending callbacks. Excess callbacks are rejected as
    # overloaded. Waiting for an actor's action mutex consumes a work slot.
    # Limits are admission limits, not parallel Ruby CPU execution or a bound
    # on upstream memory/buffered HTTP bodies.
    #
    # Stop requests initiate graceful cleanup. Dispatch continues until native
    # completion or the shutdown deadline; then replies are cancelled and the
    # runner is aborted. Ruby threads are never forcibly killed. Callbacks must
    # cooperate with Context#aborted?; timeout does not guarantee final state
    # persistence or allow restart while callbacks live. Deadlines depend on MRI
    # scheduling the dispatcher, so GVL-holding native code can delay enforcement.
    # Callback StandardErrors are logged and replied through Rivet's error boundary.
    # @param workers [Integer] positive concurrent work limit (default 16)
    # @param lifecycle_workers [Integer] positive separate hook limit (default 4)
    # @param background_workers [Integer] positive separate run-hook limit (default 16)
    # @param shutdown_timeout [Numeric] positive finite shutdown seconds (default 45)
    # @param options [Hash] native runner overrides; otherwise SDK environment defaults
    # @option options [String] :endpoint engine URL; specifying it disables engine spawn
    # @option options [String] :token auth token
    # @option options [String] :namespace engine namespace
    # @option options [String] :pool existing runner pool name
    # @return [Registry] self after successful shutdown
    # @raise [ArgumentError] invalid limits or shutdown timeout
    # @raise [Error] already running, live callbacks remain, or native runner fails
    # @raise [TimeoutError] shutdown deadline expires; Ruby callbacks may remain alive
    def start(workers: 16, lifecycle_workers: 4, background_workers: 16, shutdown_timeout: 45, **options)
      raise Error, "registry still has running callbacks" if @native || @workers.any? { |thread, _| thread.alive? }
      unless [workers, lifecycle_workers, background_workers].all? { |count| count.is_a?(Integer) && count > 0 }
        raise ArgumentError, "worker limits must be positive integers"
      end
      limits = {"work" => workers, "lifecycle" => lifecycle_workers, "background" => background_workers}
      @shutdown_timeout = Rivet.timeout_ms(shutdown_timeout) / 1000.0
      @shutdown_deadline = nil
      definitions = @actors.transform_values do |actor|
        actor.options.merge(actions: actor.actions.keys, queues: actor.queues.keys, run: actor.hooks.key?("run"))
      end
      @native = NativeRunner.start(Rivet.dump(definitions), Rivet.dump(options))
      begin
        loop do
          if @shutdown_deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @shutdown_deadline
            raise TimeoutError, "registry shutdown timed out; Ruby callbacks may still be running"
          end
          callback = @native.poll
          @workers.delete_if { |thread, _| !thread.alive? }
          @instances.delete_if { |_, (_, ctx)| ctx.finished? }
          if callback
            next unless callback.active?
            lane = callback.lane
            limit = limits.fetch(lane)
            if @workers.count { |_, call| call.lane == lane } >= limit
              callback.reject(limit)
              next
            end
            native_ctx = callback.context
            metadata = JSON.parse(native_ctx.metadata)
            actor, = @instances[metadata.fetch("activation")] ||= [@actors.fetch(metadata.fetch("name")).new, native_ctx]
            thread = Thread.new(callback, native_ctx, actor) do |call, ctx, instance|
              dispatch(call, ctx, instance)
            end
            @workers[thread] = callback
          elsif @native.finished?
            break
          end
        end
        @native.finish
      ensure
        @native.stop
        @shutdown_deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + @shutdown_timeout
        @workers.each do |thread, callback|
          callback.cancel
          thread.join([@shutdown_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
        end
        @native.abort
        @instances.clear
        @native = nil
        if @workers.any? { |thread, _| thread.alive? }
          raise TimeoutError, "registry shutdown timed out; Ruby callbacks may still be running"
        end
      end
      self
    end

    # Request shutdown without waiting, starting the deadline only once.
    # Safe to request from another Ruby thread; no-op when not running. The
    # thread executing {#start} performs cleanup and reports shutdown failures.
    # @return [nil]
    def stop
      @shutdown_deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + @shutdown_timeout if @native
      @native&.stop
    end

    private

    # Run one callback and translate exceptions to native error replies.
    # @api private
    # @param callback [NativeCallback] request and reply channel
    # @param native_ctx [NativeContext] activation context
    # @param actor [Actor] activation instance
    # @return [nil]
    def dispatch(callback, native_ctx, actor)
      ctx = Context.new(native_ctx, actor, callback)
      result = actor.dispatch(callback.kind, ctx, JSON.parse(callback.data))
      callback.reply(Rivet.dump(result), nil)
    rescue StandardError => error
      warn "Rivet #{callback.kind}: #{error.class}: #{error.message}"
      callback.reply("null", "#{error.class}: #{error.message}")
    ensure
      callback.cancel
    end
  end
end
