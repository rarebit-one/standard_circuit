module StandardCircuit
  # Opt-in rules that let a dependency's health row report :degraded on
  # evidence from its rolling stats, not only on its breaker color. Both are
  # off unless the dependency declares them:
  #
  #   c.dependency :stripe, criticality: :critical,
  #                health: { error_rate: 0.25, slow_ms: 2000, min_calls: 20 }
  #   c.register :sendgrid, health: { error_rate: 0.5 }
  #
  # * +error_rate+ — the purpose is "erroring" when its error rate (failures
  #   over attempted calls) is at or above this share, 0 < x <= 1.
  # * +slow_ms+ — the purpose is "slow" when its p95 latency is at or above
  #   this many milliseconds.
  # * +min_calls+ — neither rule applies until the purpose's window holds at
  #   least this many attempted calls (success + failure). Default 20: an
  #   error rate over a handful of calls means little.
  #
  # Rules are evaluated per purpose, on that purpose's own stats, so the
  # purpose's criticality decides what a breach costs (see HealthRow).
  class HealthRules < Data.define(:error_rate, :slow_ms, :min_calls)
    DEFAULT_MIN_CALLS = 20
    KEYS = [ :error_rate, :slow_ms, :min_calls ].freeze

    # nil (no rules) for nil; raises ArgumentError for anything malformed, at
    # configure time rather than on a health request.
    def self.build(options, owner)
      return nil if options.nil?
      raise ArgumentError, "health: for #{owner} must be a Hash; got #{options.class}" unless options.is_a?(Hash)

      options = options.transform_keys(&:to_sym)
      unknown = options.keys - KEYS
      raise ArgumentError, "unknown health: option(s) #{unknown.inspect} for #{owner}; allowed: #{KEYS.inspect}" if unknown.any?

      error_rate = options[:error_rate]
      unless error_rate.nil? || (error_rate.is_a?(Numeric) && error_rate.positive? && error_rate <= 1)
        raise ArgumentError, "health: error_rate for #{owner} must be a share in (0, 1]; got #{error_rate.inspect}"
      end

      slow_ms = options[:slow_ms]
      unless slow_ms.nil? || (slow_ms.is_a?(Numeric) && slow_ms.positive?)
        raise ArgumentError, "health: slow_ms for #{owner} must be a positive number; got #{slow_ms.inspect}"
      end

      min_calls = options.fetch(:min_calls, DEFAULT_MIN_CALLS)
      unless min_calls.is_a?(Integer) && min_calls.positive?
        raise ArgumentError, "health: min_calls for #{owner} must be a positive Integer; got #{min_calls.inspect}"
      end

      new(error_rate: error_rate, slow_ms: slow_ms, min_calls: min_calls)
    end

    # True when the error-rate rule is on and +stats+ breach it.
    def erroring?(stats)
      return false if error_rate.nil? || !enough?(stats)

      !stats[:error_rate].nil? && stats[:error_rate] >= error_rate
    end

    # True when the slow rule is on and +stats+ breach it.
    def slow?(stats)
      return false if slow_ms.nil? || !enough?(stats)

      p95 = stats.dig(:latency_ms, :p95)
      !p95.nil? && p95 >= slow_ms
    end

    private

    def enough?(stats)
      counts = stats[:counts] || {}
      (counts[:success].to_i + counts[:failure].to_i) >= min_calls
    end
  end
end
