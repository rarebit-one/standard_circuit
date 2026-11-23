module StandardCircuit
  class Runner
    # Name of the Stoplight system that owns every light this gem builds. It
    # namespaces Redis keys (`stoplight:v6:<system id>:...`), so it must stay
    # stable across processes and deploys.
    SYSTEM_NAME = "standard_circuit"

    def initialize
      @lights = Concurrent::Map.new
      @forced_states = Concurrent::Map.new
      @config = Config.new
      @system_mutex = Mutex.new
      @system_entry = nil
    end

    def apply_config!(config)
      @config = config
      discard_system!
    end

    # +name+ is a dependency or a circuit (see Config#run_target). Forced
    # states and the light are keyed by the resolved circuit, so purposes that
    # share a breaker share its forced state too.
    def run(name, purpose: nil, fallback: nil, &block)
      fallback = accept_error_argument(fallback)
      target = @config.run_target(name, purpose)
      forced = @forced_states[target.circuit]
      return run_forced_open(target, fallback) if forced == :open
      return yield if forced == :closed

      execute(target, fallback, &block)
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

    # Full state reset for tests. Clears the light cache, forced states, AND
    # swaps the Stoplight data store to a fresh Memory instance. Clearing the
    # cache alone is not sufficient: failure counters live in the data store,
    # so a spec that deliberately trips a circuit would otherwise leak RedLight
    # into later specs. We only swap the store when the existing one is already
    # a Memory store, because replacing a Redis store (production config) would
    # silently defeat shared-process coordination.
    #
    # Under stoplight 6 a Memory store is only a marker: each light keeps its
    # own counters, and a Stoplight system hands back the same cached light for
    # a name forever. So a fresh store also means a fresh system (see #system).
    def reset!
      @forced_states.clear
      @config.data_store = Stoplight::DataStore::Memory.new if @config.data_store.is_a?(Stoplight::DataStore::Memory)
      discard_system!
    end

    def light_for(name)
      key = name.to_sym
      current_system = system
      @lights.compute_if_absent(key) { build_light(current_system, key) }
    end

    # One circuit's current state: the light's own +color+ and +locked+ (as
    # health_report shows them) plus any +forced+ override (:open / :closed)
    # from force_open / force_closed.
    def circuit_state(name)
      key = name.to_sym
      light = light_for(key)
      { name: key, color: light.color.to_s, locked: Health.locked?(light, @config), forced: @forced_states[key] }
    end

    # Lock a circuit's light open (red) or closed (green) until #unlock. The
    # lock lives in the data store: per process with Memory, shared by every
    # process with Redis.
    def lock(name, state)
      color = { open: Stoplight::Color::RED, closed: Stoplight::Color::GREEN }.fetch(state)
      light_for(name).lock(color)
    end

    def unlock(name)
      light_for(name).unlock
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

    # Atomic health report — takes a single snapshot and returns both the
    # rolled-up status and the per-circuit list. Preferred for rendering a
    # health-check endpoint so status and circuits describe the same moment.
    def health_report
      snapshot = health_snapshot
      { status: Health.overall(snapshot), circuits: snapshot }
    end

    private

    # A fallback is called with one argument: the error, or nil when the
    # circuit is forced open. A zero-argument lambda (`-> { ... }`, the
    # natural way to write "return this instead") raises ArgumentError on that
    # call, so the fallback would crash at exactly the moment the circuit
    # opens. Accept it, and a zero-arity Method (`fallback: method(:degraded)`),
    # by calling it without the argument. Procs, and callables that take the
    # error, are passed through unchanged.
    def accept_error_argument(fallback)
      strict = fallback.is_a?(Method) || (fallback.is_a?(Proc) && fallback.lambda?)
      return fallback unless strict && fallback.arity.zero?

      ->(_error) { fallback.call }
    end

    def execute(target, fallback, &block)
      name = target.circuit
      started_at = monotonic_now
      light = light_for(name)
      spec = @config.spec_for(name)

      # The spec's error lists go in per run, which stoplight 6 still accepts
      # for any `===` matcher (procs, anonymous classes) — at registration it
      # only takes named classes/modules. See #build_light.
      result = light.run(fallback, tracked_errors: spec.tracked_errors, skipped_errors: spec.skipped_errors, &block)
      duration = duration_ms(started_at)
      emit_request_metric(name, :success, duration)
      emit_run_completed(target, status: :success, duration_ms: duration)
      result
    rescue Stoplight::Error::RedLight => e
      duration = duration_ms(started_at)
      emit_request_metric(name, :circuit_open, duration)
      emit_run_completed(target, status: :circuit_open, duration_ms: duration, error: e)
      raise e unless fallback

      emit_fallback_invoked(target, reason: :circuit_open)
      fallback.call(nil)
    rescue StandardError => e
      duration = duration_ms(started_at)
      emit_request_metric(name, :failure, duration)
      emit_run_completed(target, status: :failure, duration_ms: duration, error: e)
      raise e
    end

    def run_forced_open(target, fallback)
      name = target.circuit
      emit_request_metric(name, :circuit_open, 0)
      emit_run_completed(target, status: :circuit_open, duration_ms: 0)
      if fallback
        emit_fallback_invoked(target, reason: :forced_open)
        return fallback.call(nil)
      end

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

    # The Stoplight system for the current config and data store, built on
    # first use. A data store swapped in after `configure` (as #reset! does,
    # or a host assigning `config.data_store` directly) gets a new system, the
    # same way 5.x lights picked up `@config.data_store` when they were built.
    def system
      entry = @system_entry
      return entry.last if entry && entry.first.equal?(@config.data_store)

      @system_mutex.synchronize do
        store = @config.data_store
        unless @system_entry&.first.equal?(store)
          @lights.clear
          @system_entry = [ store, build_system(store) ].freeze
        end
        @system_entry.last
      end
    end

    def discard_system!
      @system_mutex.synchronize do
        @system_entry = nil
        @lights.clear
      end
    end

    # Stoplight 6 caches one light per name inside a system and refuses to
    # re-register a name with different settings, and its public
    # `register_system` refuses to reuse a system name. Neither fits a runner
    # that is reconfigured on every code reload and reset between specs, so
    # each system gets its own Stoplight state rather than living in the
    # process-global one. That also keeps it apart from a host's own
    # `Stoplight.configure`.
    def build_system(data_store)
      state = Stoplight::Wiring::GlobalState.new(
        default_config: Stoplight::Wiring::DefaultConfiguration.new.to_config!
      )
      state.register_system(SYSTEM_NAME, data_store: data_store, notifiers: [ NotifierBridge.new(@config) ])
    end

    def build_light(system, name)
      spec = @config.spec_for(name) or raise UnknownCircuit, "no circuit registered for #{name.inspect}"

      system.register(
        name.to_s,
        threshold: spec.threshold,
        cool_off_time: whole_seconds(spec.cool_off_time),
        window_size: whole_seconds(spec.window_size),
        **registrable_errors(spec)
      )
    end

    # Stoplight 6 takes only whole seconds, at least 1, for both durations.
    def whole_seconds(value)
      value && [ value.ceil, 1 ].max
    end

    # Registration accepts named classes/modules only. Lists that qualify are
    # registered so a light used directly (`light_for(name).run`) still sees
    # them; #execute passes both lists on every run regardless.
    def registrable_errors(spec)
      { tracked_errors: spec.tracked_errors, skipped_errors: spec.skipped_errors }.select do |_, errors|
        errors.all? { |matcher| matcher.is_a?(Module) && matcher.name }
      end
    end

    def emit_request_metric(name, status, duration)
      prefix = @config.metric_prefix
      attrs = { service: name.to_s, status: status.to_s }
      ::Sentry::Metrics.count("#{prefix}.request", value: 1, attributes: attrs)
      ::Sentry::Metrics.distribution("#{prefix}.request.duration", duration, unit: "millisecond", attributes: attrs)
    end

    # Per-call events carry the purpose's criticality: one shared breaker can
    # serve purposes of different weight. For a circuit registered with
    # `register`/`register_prefix` that is the circuit's own criticality.
    def emit_fallback_invoked(target, reason:)
      EventEmitter.emit("standard_circuit.circuit.fallback_invoked",
        circuit: target.circuit.to_s,
        reason: reason,
        criticality: target.criticality)
    end

    def emit_run_completed(target, status:, duration_ms:, error: nil)
      EventEmitter.emit("standard_circuit.run.completed",
        circuit: target.circuit.to_s,
        status: status,
        duration_ms: duration_ms,
        criticality: target.criticality,
        error_class: error&.class&.name,
        error_message: error&.message,
        dependency: target.dependency,
        purpose: target.purpose)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def duration_ms(started_at)
      ((monotonic_now - started_at) * 1000.0).round(2)
    end
  end
end
