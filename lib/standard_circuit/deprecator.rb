require "active_support"
require "active_support/deprecation"

module StandardCircuit
  # The gem's ActiveSupport::Deprecation instance. Registered with the host as
  # `Rails.application.deprecators[:standard_circuit]` by the engine, so the
  # host's `config.active_support.deprecation` behaviour (log / raise /
  # silence / report) applies to StandardCircuit deprecations too.
  def self.deprecator
    @deprecator ||= ActiveSupport::Deprecation.new("0.6", "StandardCircuit")
  end
end
