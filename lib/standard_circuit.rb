require "stoplight"
require "concurrent"
require "sentry-ruby"

require "standard_circuit/version"
require "standard_circuit/deprecator"
require "standard_circuit/network_errors"
require "standard_circuit/adapter_errors/stripe"
require "standard_circuit/adapter_errors/aws"
require "standard_circuit/adapter_errors/faraday"
require "standard_circuit/adapter_errors/smtp"
require "standard_circuit/adapter_errors/postmark"
require "standard_circuit/error_taxonomies"
require "standard_circuit/presets"
require "standard_circuit/event_emitter"
require "standard_circuit/notifier_bridge"
require "standard_circuit/notifiers/logger"
require "standard_circuit/notifiers/sentry"
require "standard_circuit/notifiers/metrics"
require "standard_circuit/stats"
require "standard_circuit/subscribers"
require "standard_circuit/health_rules"
require "standard_circuit/dependency_spec"
require "standard_circuit/config"
require "standard_circuit/dependency"
require "standard_circuit/health_row"
require "standard_circuit/health"
require "standard_circuit/runner"
require "standard_circuit/mailer/circuit_open_error"
require "standard_circuit/mailer/delivery_method"
require "standard_circuit/mailer/retry"
require "standard_circuit/controller_support"
require "standard_circuit/health_contribution"
require "standard_circuit/engine" if defined?(::Rails::Engine)

module StandardCircuit
  class Error < StandardError; end
  class UnknownCircuit < Error; end
  class UnknownDependency < UnknownCircuit; end
  # `run` named a purpose the dependency does not declare.
  class UnknownPurpose < Error; end
  # `run` gave no purpose for a dependency with several and no default.
  class PurposeRequired < Error; end

  class << self
    def configure
      yield config
      runner.apply_config!(config)
      stats.window_size = config.stats_window_size
      subscribers.setup!
      Mailer::Retry.install_on_load if config.mailer_retry
      config
    end

    def config
      @config ||= Config.new
    end

    # Bound to +config+ from the start, not only from the first `configure`:
    # otherwise a circuit registered straight on `StandardCircuit.config` is
    # visible to `dependency` and `health_report` readers of the config but
    # unknown to `run` until something calls `configure`.
    def runner
      @runner ||= Runner.new(config)
    end

    def subscribers
      @subscribers ||= Subscribers.new
    end

    # Rolling per-dependency / per-purpose call stats (see Stats), read
    # through `dependency(name).stats`.
    def stats
      @stats ||= Stats::Store.new(window_size: config.stats_window_size)
    end

    def run(name, purpose: nil, fallback: nil, &block)
      runner.run(name, purpose: purpose, fallback: fallback, &block)
    end

    # The dependency +name+ (see Config#dependency), or the one a
    # `register` / `register_prefix` call created. Raises UnknownDependency.
    def dependency(name)
      Dependency.new(config.dependency_spec(name), runner, config)
    end

    def dependencies
      config.dependency_specs.map { |spec| Dependency.new(spec, runner, config) }
    end

    def force_open(name, &block)
      runner.force_open(name, &block)
    end

    def force_closed(name, &block)
      runner.force_closed(name, &block)
    end

    def reset_force!
      runner.reset_force!
    end

    def reset!
      runner.reset!
      stats.clear!
    end

    # Unlock every circuit locked through `dependency(name).lock_open!` /
    # `lock_closed!` (or a purpose's) in this process and not unlocked since.
    # For a test suite that doesn't load standard_circuit/rspec:
    #
    #   config.after { StandardCircuit.reset_locks! }
    #
    # Breaker state, forced states and the data store are left alone.
    def reset_locks!
      runner.reset_locks!
    end

    # Breaker colors only, rolled up to :ok | :degraded | :critical. What
    # standard_health < 0.10 folds into its aggregate tier as `circuits`.
    # Superseded by `health_rows`; removed in 1.0 along with that fold-in.
    def health_report
      runner.health_report
    end

    # One row per dependency, with stats per purpose, for dashboards and
    # debugging. See Dependency#report.
    def dependency_report
      dependencies.map(&:report)
    end

    # One health row per dependency (see HealthRow): what StandardCircuit
    # contributes to standard_health >= 0.10, which renders them as the
    # aggregate tier's `dependencies`.
    def health_rows
      dependencies.map(&:health_row)
    end
  end
end
