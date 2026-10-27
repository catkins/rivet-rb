module Rivet
  class Registry
    def initialize(**actors)
      raise ArgumentError, "register at least one actor" if actors.empty?
      actors.each_value do |actor|
        raise ArgumentError, "actors must inherit Rivet::Actor" unless actor.is_a?(Class) && actor < Actor
      end
      @actors = actors.transform_keys(&:to_s)
      @instances = {}
      @workers = []
    end

    def start(**options)
      raise Error, "registry is already running" if @native
      definitions = @actors.transform_values do |actor|
        actor.options.merge(actions: actor.actions.keys, queues: actor.queues.keys)
      end
      @native = NativeRunner.start(JSON.generate(definitions), JSON.generate(options))
      begin
        loop do
          callback = @native.poll
          if callback
            next unless callback.active?
            native_ctx = callback.context
            metadata = JSON.parse(native_ctx.metadata)
            actor = @instances[metadata.fetch("id")] ||= @actors.fetch(metadata.fetch("name")).new
            @workers.reject! { |worker| !worker.alive? }
            @workers << Thread.new(callback, native_ctx, actor, metadata.fetch("id")) do |call, ctx, instance, id|
              dispatch(call, ctx, instance, id)
            end
          elsif @native.finished?
            break
          end
        end
        @native.finish
      ensure
        @native.stop
        @workers.each(&:join)
        @instances.clear
        @native = nil
      end
      self
    end

    def stop
      @native&.stop
    end

    private

    def dispatch(callback, native_ctx, actor, id)
      ctx = Context.new(native_ctx, actor, callback)
      result = actor.dispatch(callback.kind, ctx, JSON.parse(callback.data))
      callback.reply(JSON.generate(result), nil)
    rescue StandardError => error
      warn "Rivet #{callback.kind}: #{error.class}: #{error.message}"
      callback.reply("null", "#{error.class}: #{error.message}")
    ensure
      @instances.delete(id) if %w[on_sleep on_destroy].include?(callback.kind)
    end
  end
end
