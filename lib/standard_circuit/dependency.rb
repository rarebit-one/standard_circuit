module StandardCircuit
  # Runtime view of one dependency, returned by `StandardCircuit.dependency`.
  # Cheap to build: it keeps the definition it was built from and reads
  # breaker state from the live runner on every call. After a `configure`
  # that changes the dependency, fetch a fresh handle; one kept from before
  # still describes the old purposes and breakers.
  #
  # State is whatever the data store holds: per process with the default
  # Memory store, shared across processes with Redis (see README).
  class Dependency
    STATUS_RANK = { ok: 0, degraded: 1, unavailable: 2 }.freeze
    COLOR_RANK = { "green" => 0, "yellow" => 1, "red" => 2 }.freeze

    # A forced override wins over the light's color, as it does for `run`.
    def self.effective_color(state)
      case state[:forced]
      when :open then "red"
      when :closed then "green"
      else state[:color]
      end
    end

    def self.worst_color(states)
      states.map { |state| effective_color(state) }.max_by { |color| COLOR_RANK.fetch(color, 0) } || "green"
    end

    attr_reader :spec, :runner, :config, :stats_store

    def initialize(spec, runner, config, stats_store: StandardCircuit.stats)
      @spec = spec
      @runner = runner
      @config = config
      @stats_store = stats_store
    end

    def name
      @spec.name
    end

    # The worst criticality among the purposes.
    def criticality
      @spec.criticality
    end

    def prefix?
      @spec.prefix?
    end

    def purposes
      @spec.purposes.map { |purpose_spec| Purpose.new(self, purpose_spec) }
    end

    # Raises UnknownPurpose for a purpose the dependency does not declare.
    def purpose(name)
      Purpose.new(self, @spec.purpose(name))
    end

    # Names of the circuits (breakers) behind this dependency. For a prefix
    # registration these are the `<prefix>_*` circuits used so far in this
    # process — they can't be enumerated any other way (see Health).
    def circuit_names
      return @spec.circuits.keys unless prefix?

      @runner.cached_lights.keys.select do |circuit|
        !@config.circuits.key?(circuit) && @config.run_target(circuit).dependency == name
      end
    end

    # Current state of every circuit behind the dependency:
    # `{ name:, color:, locked:, forced: }` (see Runner#circuit_state).
    def circuits
      circuit_names.map { |circuit| @runner.circuit_state(circuit) }
    end

    # True when every purpose is metrics-only (see Config#dependency).
    def metrics_only?
      purposes.all?(&:metrics_only?)
    end

    # Rolling stats over the dependency's recent calls, all purposes
    # together. See Stats.summarize for the shape; `calls: 0` and nil rates
    # mean no evidence yet, not health.
    def stats
      @stats_store.for_dependency(name)
    end

    # One row of StandardCircuit.dependency_report. Circuit state is read
    # once and every field is derived from that read, so status, open and
    # the purposes can't describe different moments.
    def report
      states = circuits
      by_name = states.to_h { |state| [ state[:name], state ] }
      purpose_rows = purposes.map do |purpose|
        purpose.report(prefix? ? states : by_name.values_at(*purpose.circuit_names).compact)
      end

      {
        name: name,
        status: purpose_rows.map { |row| row[:status] }.max_by { |status| STATUS_RANK.fetch(status) },
        criticality: criticality,
        open: purpose_rows.all? { |row| row[:open] },
        metrics_only: purpose_rows.all? { |row| row[:metrics_only] },
        stats: stats,
        purposes: purpose_rows,
        circuits: states
      }
    end

    # True when no purpose can be served: every purpose's breaker is open
    # (red, or forced open). For the usual one-breaker dependency that is
    # simply "its breaker is open". Half-open (yellow) is not open: calls go
    # through as recovery probes.
    def open?
      purposes.all?(&:open?)
    end

    # :ok | :degraded | :unavailable — the worst purpose's status. Each
    # purpose applies the health_report rule to its criticality and breaker
    # color: critical + red is unavailable; critical + yellow or standard +
    # red is degraded; optional never elevates.
    def status
      purposes.map(&:status).max_by { |status| STATUS_RANK.fetch(status) }
    end

    # Lock every breaker behind the dependency open (calls raise RedLight, or
    # return their fallback) or closed (calls always go through) until
    # #unlock!. For a prefix dependency that covers the sub-circuits used so
    # far in this process.
    def lock_open!
      circuit_names.each { |circuit| @runner.lock(circuit, :open) }
      self
    end

    def lock_closed!
      circuit_names.each { |circuit| @runner.lock(circuit, :closed) }
      self
    end

    def unlock!
      circuit_names.each { |circuit| @runner.unlock(circuit) }
      self
    end

    def inspect
      "#<#{self.class.name} #{name.inspect} purposes=#{@spec.purpose_names.inspect}>"
    end

    # One declared reason to call a dependency.
    class Purpose
      attr_reader :dependency, :spec

      def initialize(dependency, spec)
        @dependency = dependency
        @spec = spec
      end

      def name
        @spec.name
      end

      def criticality
        @spec.criticality
      end

      # The circuit guarding calls for this purpose: the dependency's shared
      # breaker, or the purpose's own when isolated. nil for a prefix
      # dependency, whose circuit depends on the name each call uses.
      def circuit_name
        @spec.circuit
      end

      def isolated?
        @spec.isolated?
      end

      def default?
        @spec.default?
      end

      # The purpose's breaker; for a prefix dependency, its sub-circuits.
      def circuit_names
        @spec.circuit ? [ @spec.circuit ] : dependency.circuit_names
      end

      def circuits
        circuit_names.map { |circuit| dependency.runner.circuit_state(circuit) }
      end

      # Calls are timed and recorded but never blocked (`metrics_only: true`
      # on the dependency, or on an isolated purpose).
      def metrics_only?
        spec = dependency.prefix? ? dependency.config.prefixes[dependency.spec.prefix] : dependency.config.spec_for(circuit_name)
        spec&.metrics_only || false
      end

      # The breaker's color with forced overrides applied: "green" | "yellow"
      # | "red". The worst sub-circuit's for a prefix dependency. Always
      # "green" when metrics-only: such a breaker never blocks a call.
      def color
        color_for(circuits)
      end

      # True while the breaker is open (red, or forced open). A prefix
      # dependency's purpose is open only when every sub-circuit used so far
      # is, and never before one has been used. Never true when metrics-only.
      def open?
        open_for(circuits)
      end

      # Rolling stats over this purpose's recent calls (see Dependency#stats).
      def stats
        dependency.stats_store.for_purpose(dependency.name, name)
      end

      # +states+: this purpose's circuit states, when the caller already has them.
      def report(states = circuits)
        {
          name: name,
          criticality: criticality,
          status: status_for(states),
          open: open_for(states),
          isolated: isolated?,
          metrics_only: metrics_only?,
          circuits: circuit_names,
          stats: stats
        }
      end

      # :ok | :degraded | :unavailable, from criticality and #color.
      def status
        status_for(circuits)
      end

      # Locks this purpose's breaker. A purpose that shares the dependency's
      # breaker locks it for every purpose sharing it.
      def lock_open!
        circuit_names.each { |circuit| dependency.runner.lock(circuit, :open) }
        self
      end

      def lock_closed!
        circuit_names.each { |circuit| dependency.runner.lock(circuit, :closed) }
        self
      end

      def unlock!
        circuit_names.each { |circuit| dependency.runner.unlock(circuit) }
        self
      end

      def inspect
        "#<#{self.class.name} #{dependency.name.inspect}/#{name.inspect} criticality=#{criticality.inspect}>"
      end

      private

      def color_for(states)
        metrics_only? ? "green" : Dependency.worst_color(states)
      end

      def open_for(states)
        return false if metrics_only?

        states.any? && states.all? { |state| Dependency.effective_color(state) == "red" }
      end

      def status_for(states)
        Health.severity(criticality, color_for(states))
      end
    end
  end
end
