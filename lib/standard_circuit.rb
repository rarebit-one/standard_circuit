require "stoplight"
require "concurrent"
require "sentry-ruby"

require "standard_circuit/version"
require "standard_circuit/network_errors"
require "standard_circuit/adapter_errors/stripe"
require "standard_circuit/adapter_errors/aws"
require "standard_circuit/adapter_errors/faraday"
require "standard_circuit/adapter_errors/smtp"
require "standard_circuit/error_taxonomies"
require "standard_circuit/notifiers/logger"
require "standard_circuit/notifiers/sentry"
require "standard_circuit/notifiers/metrics"
require "standard_circuit/config"
require "standard_circuit/health"
require "standard_circuit/runner"
require "standard_circuit/mailer/circuit_open_error"
require "standard_circuit/mailer/delivery_method"
require "standard_circuit/controller_support"

module StandardCircuit
  class Error < StandardError; end
  class UnknownCircuit < Error; end

  class << self
    def configure
      yield config
      runner.apply_config!(config)
      config
    end

    def config
      @config ||= Config.new
    end

    def runner
      @runner ||= Runner.new
    end

    def run(name, fallback: nil, &block)
      runner.run(name, fallback: fallback, &block)
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

    def health_snapshot
      runner.health_snapshot
    end

    def health_overall(snapshot = nil)
      runner.health_overall(snapshot)
    end

    def health_report
      runner.health_report
    end
  end
end
