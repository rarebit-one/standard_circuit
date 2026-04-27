module StandardCircuit
  # Boot hook: register the internal Logger / Sentry / Metrics subscribers (and
  # any `extra_notifiers` the host configured) against whichever event bus is
  # live in this Rails version.
  #
  # We hook on :before_eager_load rather than :active_record because the
  # circuit breaker is independent of ActiveRecord — apps that don't load AR
  # still need observability.
  class Engine < ::Rails::Engine
    initializer "standard_circuit.subscribers", after: :load_config_initializers do
      StandardCircuit.subscribers.setup!
    end
  end
end
