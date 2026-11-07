module Rivet
  class Registry
    def initialize(**actors)
      raise ArgumentError, "register at least one actor" if actors.empty?
      actors.each_value do |actor|
        raise ArgumentError, "actors must inherit Rivet::Actor" unless actor.is_a?(Class) && actor < Actor
      end
      @actors = actors.transform_keys(&:to_s)
      @instances = {}
      @workers = {}
    end

    def start(workers: 16, lifecycle_workers: 4, shutdown_timeout: 45, **options)
      raise Error, "registry still has running callbacks" if @native || @workers.any? { |thread, _| thread.alive? }
      unless [workers, lifecycle_workers].all? { |count| count.is_a?(Integer) && count > 0 }
        raise ArgumentError, "worker limits must be positive integers"
      end
      @shutdown_timeout = Rivet.timeout_ms(shutdown_timeout) / 1000.0
      @shutdown_deadline = nil
      definitions = @actors.transform_values do |actor|
        actor.options.merge(actions: actor.actions.keys, queues: actor.queues.keys)
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
            work = callback.work?
            limit = work ? workers : lifecycle_workers
            if @workers.count { |_, call| call.work? == work } >= limit
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

    def stop
      @shutdown_deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + @shutdown_timeout if @native
      @native&.stop
    end

    private

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
