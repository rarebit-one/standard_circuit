module StandardCircuit
  # Boot hook: register the internal Logger / Sentry / Metrics subscribers (and
  # any `extra_notifiers` the host configured) against whichever event bus is
  # live in this Rails version.
  #
  # We hook `after: :load_config_initializers` so any host-side
  # `StandardCircuit.configure` block in `config/initializers/*` has finished
  # running and `extra_notifiers` / `metric_prefix` / `logger` are in their
  # final state when the subscriber set is built. This is independent of
  # ActiveRecord — apps that don't load AR still need observability.
  class Engine < ::Rails::Engine
    initializer "standard_circuit.subscribers", after: :load_config_initializers do
      StandardCircuit.subscribers.setup!
    end
  end
end
