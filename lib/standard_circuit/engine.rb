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
    # Brings StandardCircuit in line with the other engine gems in the family.
    # Safe here specifically because this engine is library-only:
    #
    # * No `config/routes.rb`, so the `default_scope` isolate_namespace applies
    #   to the engine's own route set has nothing to scope.
    # * No ActiveRecord models, so the `standard_circuit_` table_name_prefix it
    #   defines on the StandardCircuit module applies to nothing.
    # * The host-drawn route the convention prescribes —
    #   `get "/health", to: "standard_circuit/health#show"` — resolves through
    #   the *application's* route set by constant lookup, which isolation does
    #   not touch. Verified by booting a real Rails app both ways (see
    #   spec/integration/health_route_boot_spec.rb, which fails if this ever
    #   regresses).
    #
    # One real consequence: `StandardCircuit::HealthController` now picks up the
    # engine's (empty) url_helpers instead of the application's, so app path
    # helpers inside it — or inside a host subclass of it — need a `main_app.`
    # prefix. The controller only renders JSON, so nothing in-gem is affected.
    isolate_namespace StandardCircuit

    initializer "standard_circuit.subscribers", after: :load_config_initializers do
      StandardCircuit.subscribers.setup!
    end
  end
end
