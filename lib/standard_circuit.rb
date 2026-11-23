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
require "standard_circuit/subscribers"
require "standard_circuit/dependency_spec"
require "standard_circuit/config"
require "standard_circuit/dependency"
require "standard_circuit/health"
require "standard_circuit/runner"
require "standard_circuit/mailer/circuit_open_error"
require "standard_circuit/mailer/delivery_method"
require "standard_circuit/mailer/retry"
require "standard_circuit/controller_support"
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
      subscribers.setup!
      Mailer::Retry.install_on_load if config.mailer_retry
      config
    end

    def config
      @config ||= Config.new
    end

    def runner
      @runner ||= Runner.new
    end

    def subscribers
      @subscribers ||= Subscribers.new
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
    end

    def health_report
      runner.health_report
    end
  end
end
