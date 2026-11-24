module StandardCircuit
  # The row one dependency contributes to StandardHealth (see
  # health_contribution.rb), also returned by `Dependency#health_row`:
  #
  #   { name: "stripe", status: :degraded, criticality: :critical,
  #     affected_purposes: ["checkout"], reasons: ["error_rate"],
  #     metrics_only: false,
  #     circuits: [{ name: "stripe", color: "green", locked: false }],
  #     measurements: { "stripe:errorRate" => 0.18, "stripe:p95Ms" => 2140.0,
  #                     "stripe:lastSuccessAt" => "2026-11-23T04:12:09Z",
  #                     "stripe:fallbackRate" => 0.04 } }
  #
  # STATUS. Each purpose is judged on its own breaker and its own stats, and
  # what a finding costs depends on that purpose's criticality:
  #
  #   finding (reason)               critical      standard   optional
  #   breaker open      (open)       unavailable   degraded   ok
  #   half-open         (half_open)  degraded      degraded   ok
  #   error rate over   (error_rate) degraded      degraded   ok
  #   slow              (slow)       degraded      ok         ok
  #   none                           ok            ok         ok
  #
  # The row takes the worst purpose's status. `affected_purposes` lists every
  # purpose with a finding (even one that costs nothing, such as an optional
  # purpose's open breaker), and `reasons` the findings, in the table's order.
  #
  # The breaker rows match `health_report` except one: a :standard purpose
  # whose breaker is half-open is :degraded here, where `health_report` says
  # :ok. The error_rate and slow findings need HealthRules, which are off
  # unless the dependency declares `health:`. A metrics-only purpose has no
  # breaker findings (its breaker never opens) and never reports
  # :unavailable, so it cannot fail readiness.
  #
  # MEASUREMENTS. Exactly four per dependency, keyed `<dependency>:<name>` in
  # the IETF health-check draft's style, over the dependency's rolling window
  # (all purposes together). nil means no evidence yet, never healthy.
  #
  # `probe` is not set yet: active probes (0.10) will add a cached result
  # under that key.
  module HealthRow
    REASONS = [ :open, :half_open, :error_rate, :slow ].freeze
    MEASUREMENTS = [ "errorRate", "p95Ms", "lastSuccessAt", "fallbackRate" ].freeze
    STATUS_RANK = Dependency::STATUS_RANK

    TABLE = {
      open: { critical: :unavailable, standard: :degraded, optional: :ok },
      half_open: { critical: :degraded, standard: :degraded, optional: :ok },
      error_rate: { critical: :degraded, standard: :degraded, optional: :ok },
      slow: { critical: :degraded, standard: :ok, optional: :ok }
    }.freeze

    module_function

    def build(dependency)
      # Circuit state is read once; every field below derives from this read.
      states = dependency.circuits
      by_name = states.to_h { |state| [ state[:name], state ] }
      rules = dependency.spec.health_rules

      findings = dependency.purposes.map do |purpose|
        purpose_states = dependency.prefix? ? states : by_name.values_at(*purpose.circuit_names).compact
        reasons = reasons_for(purpose, purpose_states, rules)
        [ purpose, reasons, status_for(purpose, reasons) ]
      end

      {
        name: dependency.name.to_s,
        status: worst(findings.map(&:last)),
        criticality: dependency.criticality,
        affected_purposes: findings.reject { |_, reasons, _| reasons.empty? }.map { |purpose, _, _| purpose.name.to_s },
        reasons: REASONS.select { |reason| findings.any? { |_, reasons, _| reasons.include?(reason) } }.map(&:to_s),
        metrics_only: dependency.metrics_only?,
        circuits: states.map do |state|
          { name: state[:name].to_s, color: Dependency.effective_color(state), locked: state[:locked] ? true : false }
        end,
        measurements: measurements(dependency.name, dependency.stats)
      }
    end

    def reasons_for(purpose, states, rules)
      reasons = []
      unless purpose.metrics_only?
        color = Dependency.worst_color(states)
        reasons << :open if color == "red"
        reasons << :half_open if color == "yellow"
      end
      if rules
        stats = purpose.stats
        reasons << :error_rate if rules.erroring?(stats)
        reasons << :slow if rules.slow?(stats)
      end
      reasons
    end

    def status_for(purpose, reasons)
      status = worst(reasons.map { |reason| TABLE.fetch(reason).fetch(purpose.criticality) })
      status == :unavailable && purpose.metrics_only? ? :degraded : status
    end

    def worst(statuses)
      statuses.max_by { |status| STATUS_RANK.fetch(status) } || :ok
    end

    def measurements(name, stats)
      values = [
        stats[:error_rate],
        stats.dig(:latency_ms, :p95),
        stats[:last_success_at]&.utc&.iso8601,
        stats[:fallback_rate]
      ]
      MEASUREMENTS.zip(values).to_h { |key, value| [ "#{name}:#{key}", value ] }
    end
  end
end
