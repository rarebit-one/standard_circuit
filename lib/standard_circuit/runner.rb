module StandardCircuit
  class Runner
    def initialize
      @lights = Concurrent::Map.new
      @forced_states = Concurrent::Map.new
      @config = Config.new
    end

    def apply_config!(config)
      @config = config
      @lights.clear
    end

    def run(name, fallback: nil, &block)
      forced = @forced_states[name.to_sym]
      return run_forced_open(name, fallback) if forced == :open
      return yield if forced == :closed

      execute(name, fallback, &block)
    end

    def force_open(name, &block)
      apply_force(name, :open, &block)
    end

    def force_closed(name, &block)
      apply_force(name, :closed, &block)
    end

    def reset_force!
      @forced_states.clear
    end

    def reset!
      @lights.clear
      @forced_states.clear
    end

    def light_for(name)
      @lights.compute_if_absent(name.to_sym) { build_light(name.to_sym) }
    end

    # Snapshot Hash of the current cached lights. Used by Health to discover
    # prefix-matched circuits that have been exercised at least once — we can't
    # enumerate prefix-matched dynamic names any other way.
    def cached_lights
      hash = {}
      @lights.each_pair { |name, light| hash[name] = light }
      hash
    end

    def health_snapshot
      Health.snapshot(self, @config)
    end

    def health_overall
      Health.overall(health_snapshot)
    end

    private

    def execute(name, fallback, &block)
      started_at = monotonic_now
      light = light_for(name)

      result = fallback ? light.run(fallback, &block) : light.run(&block)
      emit_request_metric(name, :success, duration_ms(started_at))
      result
    rescue Stoplight::Error::RedLight => e
      emit_request_metric(name, :circuit_open, duration_ms(started_at))
      raise e unless fallback

      fallback.call(nil)
    rescue StandardError => e
      emit_request_metric(name, :failure, duration_ms(started_at))
      raise e
    end

    def run_forced_open(name, fallback)
      emit_request_metric(name, :circuit_open, 0)
      return fallback.call(nil) if fallback

      spec = @config.spec_for(name)
      raise Stoplight::Error::RedLight.new(
        name.to_s,
        cool_off_time: spec&.cool_off_time || Config::DEFAULT_COOL_OFF,
        retry_after: nil
      )
    end

    def apply_force(name, state)
      key = name.to_sym
      return set_force(key, state) unless block_given?

      prior = @forced_states[key]
      set_force(key, state)
      begin
        yield
      ensure
        prior.nil? ? @forced_states.delete(key) : set_force(key, prior)
      end
    end

    def set_force(key, state)
      @forced_states[key] = state
    end

    def build_light(name)
      spec = @config.spec_for(name) or raise UnknownCircuit, "no circuit registered for #{name.inspect}"

      Stoplight.light(
        name.to_s,
        threshold: spec.threshold,
        cool_off_time: spec.cool_off_time,
        window_size: spec.window_size,
        tracked_errors: spec.tracked_errors,
        skipped_errors: spec.skipped_errors,
        data_store: @config.data_store,
        notifiers: notifiers
      )
    end

    def notifiers
      @config.notifiers
    end

    def emit_request_metric(name, status, duration)
      return unless defined?(::Sentry::Metrics)

      prefix = @config.metric_prefix
      attrs = { service: name.to_s, status: status.to_s }
      ::Sentry::Metrics.count("#{prefix}.request", value: 1, attributes: attrs)
      ::Sentry::Metrics.distribution("#{prefix}.request.duration", duration, unit: "millisecond", attributes: attrs)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def duration_ms(started_at)
      ((monotonic_now - started_at) * 1000.0).round(2)
    end
  end
end
