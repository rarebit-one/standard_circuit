module StandardCircuit
  class Runner
    # Name of the first Stoplight system a process builds for this gem's
    # lights. It namespaces Redis keys (`stoplight:v6:<system id>:...`), so
    # every process that has not rebuilt shares breaker state under it. A
    # rebuild registers the next generation, `standard_circuit_2` and so on:
    # see #register_system.
    SYSTEM_NAME = "standard_circuit"

    # Every system-level setting, pinned to stoplight's own defaults.
    # `register_system` fills each setting it is not given from the
    # process-global default config, i.e. the host's `Stoplight.configure`
    # (whatever stoplight's docs say), and validates the result: a host on
    # `traffic_control: :error_rate` with `threshold: 0.5` would otherwise make
    # registration raise. The data store and notifiers are passed per system,
    # and each light sets its own threshold, durations and error lists.
    SYSTEM_SETTINGS = {
      threshold: 3,
      cool_off_time: 60,
      window_size: nil,
      tracked_errors: [ StandardError ].freeze,
      skipped_errors: [].freeze,
      recovery_threshold: 1,
      traffic_control: :consecutive_errors,
      traffic_recovery: :consecutive_successes,
      error_notifier: ->(error) { warn error }
    }.freeze

    # What a system was built from (see #system).
    SystemEntry = Data.define(:name, :system, :data_store, :config)
    private_constant :SystemEntry

    @generation_mutex = Mutex.new
    @generation = 0

    class << self
      # The next system name this process has not used: SYSTEM_NAME, then
      # SYSTEM_NAME_2, SYSTEM_NAME_3, ... Per process and shared by every
      # Runner, because Stoplight's system registry is process-global.
      def next_system_name
        generation = @generation_mutex.synchronize { @generation += 1 }
        generation == 1 ? SYSTEM_NAME : "#{SYSTEM_NAME}_#{generation}"
      end

      # Start naming from SYSTEM_NAME again. Only for when stoplight's own
      # system registry has been emptied, so every name is free (the
      # `standard_circuit/rspec` helper does that between examples); a name
      # still taken is skipped as usual.
      # @api private
      def restart_generations!
        @generation_mutex.synchronize { @generation = 0 }
      end
    end

    def initialize(config = Config.new)
      @lights = Concurrent::Map.new
      # The settings each cached light was registered with (see #reusable?).
      @light_settings = Concurrent::Map.new
      @forced_states = Concurrent::Map.new
      @config = config
      @system_mutex = Mutex.new
      @system_entry = nil
      @check_system = false
      @rebuild_system = false
    end

    # A changed config takes effect on the next call. The system is kept, with
    # its breaker state, when the new config would build the same lights.
    def apply_config!(config)
      @system_mutex.synchronize do
        @config = config
        @check_system = true
      end
    end

    # +name+ is a dependency or a circuit (see Config#run_target). Forced
    # states and the light are keyed by the resolved circuit, so purposes that
    # share a breaker share its forced state too.
    def run(name, purpose: nil, fallback: nil, &block)
      fallback = accept_error_argument(fallback)
      target = @config.run_target(name, purpose)
      spec = @config.spec_for(target.circuit)
      return execute_metrics_only(target, spec, fallback, &block) if spec&.metrics_only

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
      @system_mutex.synchronize do
        @rebuild_system = true
        @check_system = true
      end
    end

    # Forget the current system and its lights, so the next call registers a
    # new one. For when stoplight's registry was emptied underneath it (see
    # Runner.restart_generations!); a normal rebuild goes through #system.
    # @api private
    def drop_system!
      @system_mutex.synchronize do
        @system_entry = nil
        @lights.clear
        @light_settings.clear
        @check_system = false
        @rebuild_system = false
      end
    end

    # Name of the Stoplight system this runner's lights currently live in
    # (SYSTEM_NAME or a later generation). For diagnostics and specs.
    # @api private
    def system_name
      system
      @system_entry.name
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
    # A no-op for a metrics-only circuit, whose light is never consulted.
    def lock(name, state)
      color = { open: Stoplight::Color::RED, closed: Stoplight::Color::GREEN }.fetch(state)
      light_for(name).lock(color) unless metrics_only?(name)
    end

    def unlock(name)
      light_for(name).unlock unless metrics_only?(name)
    end

    # Snapshot Hash of the current cached lights. Used by Health to discover
    # prefix-matched circuits that have been exercised at least once — we can't
    # enumerate prefix-matched dynamic names any other way.
    def cached_lights
      system # drops the cache first if a configure or reset! retired its system
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
      outcome = FallbackOutcome.new(fallback)

      # The spec's error lists go in per run, which stoplight 6 still accepts
      # for any `===` matcher (procs, anonymous classes) — at registration it
      # only takes named classes/modules. See #build_light.
      result = light.run(outcome.fallback, tracked_errors: spec.tracked_errors, skipped_errors: spec.skipped_errors, &block)
      duration = duration_ms(started_at)
      emit_request_metric(name, outcome.status, duration)
      emit_run_completed(target, status: outcome.status, duration_ms: duration, error: outcome.error, fallback_used: outcome.used?)
      result
    rescue Stoplight::Error::RedLight => e
      duration = duration_ms(started_at)
      emit_request_metric(name, :circuit_open, duration)
      return answer_with_fallback(target, fallback, reason: :circuit_open, duration_ms: duration, error: e) if fallback

      emit_run_completed(target, status: :circuit_open, duration_ms: duration, error: e)
      raise e
    rescue StandardError => e
      duration = duration_ms(started_at)
      emit_request_metric(name, :failure, duration)
      emit_run_completed(target, status: :failure, duration_ms: duration, error: e)
      raise e
    end

    # Stoplight calls the fallback itself, both for a tracked error the block
    # raised (with that error) and while the light is red (with nil), and
    # returns its value as if the block had returned it. Wrapping the fallback
    # is how the runner learns which of the three happened, so run.completed
    # and the request metric report the real outcome instead of :success.
    class FallbackOutcome
      attr_reader :error

      def initialize(fallback)
        @inner = fallback
        @used = false
      end

      def fallback
        return unless @inner

        lambda do |error|
          @used = true
          @error = error
          @inner.call(error)
        end
      end

      def used? = @used

      def status
        return :success unless @used

        @error ? :failure : :circuit_open
      end
    end
    private_constant :FallbackOutcome

    # A metrics-only breaker never blocks a call by any route: the light is
    # never consulted, and forced states and locks don't apply. Everything
    # else matches a breaker that is closed: a tracked error goes to the
    # fallback when there is one, the same events and request metrics are
    # emitted, with the same statuses (:failure for a failure the fallback
    # absorbed).
    #
    # The light is still built, though not run through, because the light
    # cache is how prefix-matched circuits (`s3_uploads`) become known to
    # Health.snapshot and Dependency#circuit_names.
    def execute_metrics_only(target, spec, fallback)
      name = target.circuit
      light_for(name)
      started_at = monotonic_now
      absorbed = nil
      result = begin
        yield
      rescue StandardError => e
        raise unless fallback && tracked_error?(spec, e)

        absorbed = e
        fallback.call(e)
      end
      duration = duration_ms(started_at)
      status = absorbed ? :failure : :success
      emit_request_metric(name, status, duration)
      emit_run_completed(target, status: status, duration_ms: duration, error: absorbed, fallback_used: !absorbed.nil?)
      result
    rescue StandardError => e
      duration = duration_ms(started_at)
      emit_request_metric(name, :failure, duration)
      emit_run_completed(target, status: :failure, duration_ms: duration, error: e)
      raise e
    end

    def metrics_only?(name)
      @config.spec_for(name)&.metrics_only
    end

    # Stoplight's rule: skipped wins over tracked.
    def tracked_error?(spec, error)
      spec.skipped_errors.none? { |matcher| matcher === error } &&
        spec.tracked_errors.any? { |matcher| matcher === error }
    end

    def run_forced_open(target, fallback)
      name = target.circuit
      emit_request_metric(name, :circuit_open, 0)
      return answer_with_fallback(target, fallback, reason: :forced_open, duration_ms: 0) if fallback

      emit_run_completed(target, status: :circuit_open, duration_ms: 0)
      spec = @config.spec_for(name)
      raise Stoplight::Error::RedLight.new(
        name.to_s,
        cool_off_time: spec&.cool_off_time || Config::DEFAULT_COOL_OFF,
        retry_after: nil
      )
    end

    # The runner's own fallback call, for a circuit the runner found open
    # (forced open, or a RedLight raised inside the block). run.completed is
    # emitted once the fallback has returned, so +fallback_used+ is only true
    # when the caller really got its value; a fallback that raises propagates
    # as before, reported with fallback_used: false.
    def answer_with_fallback(target, fallback, reason:, duration_ms:, error: nil)
      emit_fallback_invoked(target, reason: reason)
      result = fallback.call(nil)
    rescue StandardError
      emit_run_completed(target, status: :circuit_open, duration_ms: duration_ms, error: error)
      raise
    else
      emit_run_completed(target, status: :circuit_open, duration_ms: duration_ms, error: error, fallback_used: true)
      result
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
    # first use. After a `configure`, a #reset! or a data store swapped in
    # after `configure` (as #reset! does, or a host assigning
    # `config.data_store` directly), the next call checks whether the current
    # system can still serve: see #reusable?. If not, a new generation is
    # registered and the light cache starts empty.
    def system
      entry = @system_entry
      return entry.system if entry && !@check_system && entry.data_store.equal?(@config.data_store)

      @system_mutex.synchronize do
        entry = @system_entry
        if entry && reusable?(entry)
          # A reused Memory-backed system adopts the Memory store now in the
          # config, so the fast path above matches it again.
          entry = @system_entry = entry.with(data_store: @config.data_store)
        else
          @lights.clear
          @light_settings.clear
          entry = @system_entry = build_system_entry
        end
        @check_system = false
        @rebuild_system = false
        entry.system
      end
    end

    # The current system can serve the current config when every light built
    # in it is still configured with exactly the settings it was registered
    # with, on the same data store and behind the same config object (which
    # the notifier bridge reads), unless #reset! asked for fresh breaker
    # state. Circuits not built yet register in it as they are first used, so
    # adding a circuit keeps everyone else's state; changing or removing a
    # built one cannot be done in place (stoplight refuses to re-register a
    # light with other settings), so it means a new generation.
    #
    # A system no light was ever built in holds no state and no
    # registrations, so a reset, a changed config, or a Memory store swapped
    # for another Memory store (each is only a marker in stoplight 6) can all
    # reuse it. That keeps a suite that calls reset! between examples from
    # registering a system for every example that never runs a circuit.
    def reusable?(entry)
      return false unless entry.config.equal?(@config)
      return same_store?(entry.data_store, @config.data_store) if @light_settings.empty?

      !@rebuild_system && entry.data_store.equal?(@config.data_store) && built_lights_unchanged?
    end

    def built_lights_unchanged?
      @light_settings.each_pair.all? do |name, settings|
        spec = @config.spec_for(name)
        spec && light_settings(spec) == settings
      end
    end

    def same_store?(built_with, current)
      built_with.equal?(current) ||
        (built_with.is_a?(Stoplight::DataStore::Memory) && current.is_a?(Stoplight::DataStore::Memory))
    end

    def build_system_entry
      data_store = @config.data_store
      name, system = register_system(data_store)
      SystemEntry.new(name: name, system: system, data_store: data_store, config: @config)
    end

    # Registers the next generation through stoplight's public
    # `Stoplight.register_system`. It refuses a name already in use and has no
    # unregister, so a superseded generation stays registered with stoplight
    # (the runner drops every reference to it), and a name a host registered
    # itself is skipped rather than raising at boot.
    def register_system(data_store)
      loop do
        name = self.class.next_system_name
        begin
          system = Stoplight.register_system(name, **SYSTEM_SETTINGS, data_store: data_store,
                                                   notifiers: [ NotifierBridge.new(@config) ])
          return [ name, system ]
        rescue ArgumentError => e
          raise unless e.message.include?("already in use")
        end
      end
    end

    def build_light(system, name)
      spec = @config.spec_for(name) or raise UnknownCircuit, "no circuit registered for #{name.inspect}"

      settings = light_settings(spec)
      light = system.register(name.to_s, **settings)
      @light_settings[name] = settings
      light
    end

    def light_settings(spec)
      {
        threshold: spec.threshold,
        cool_off_time: whole_seconds(spec.cool_off_time),
        window_size: whole_seconds(spec.window_size),
        **registrable_errors(spec)
      }
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

    # +fallback_used+ is true when the caller got the fallback's value: a
    # failure it absorbed, an open circuit, or a forced-open one.
    def emit_run_completed(target, status:, duration_ms:, error: nil, fallback_used: false)
      EventEmitter.emit("standard_circuit.run.completed",
        circuit: target.circuit.to_s,
        status: status,
        duration_ms: duration_ms,
        criticality: target.criticality,
        error_class: error&.class&.name,
        error_message: error&.message,
        dependency: target.dependency,
        purpose: target.purpose,
        fallback_used: fallback_used)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def duration_ms(started_at)
      ((monotonic_now - started_at) * 1000.0).round(2)
    end
  end
end
