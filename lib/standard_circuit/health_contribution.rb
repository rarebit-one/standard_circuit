require "active_support/lazy_load_hooks"

# Contributes one row per registered dependency to StandardHealth (>= 0.10)
# through its load hook, so neither gem depends on the other: without
# standard_health in the bundle this block never runs. See HealthRow for the
# row and `StandardCircuit.health_rows`.
#
# standard_health 0.9 runs the hook too, but has no `contribute_dependencies`.
# It keeps folding `StandardCircuit.health_report` into its aggregate tier
# instead, so contribute nothing there.
ActiveSupport.on_load(:standard_health) do |health|
  next unless health.respond_to?(:contribute_dependencies)

  health.contribute_dependencies(:standard_circuit) { StandardCircuit.health_rows }
end
