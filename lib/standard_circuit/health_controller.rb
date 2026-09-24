# Deprecated load path, kept so `require "standard_circuit/health_controller"`
# at the top of a host's config/routes.rb (the pre-0.4 opt-in) keeps working.
#
# The controller now lives at app/controllers/standard_circuit/health_controller.rb
# and the engine autoloads it — delete the require and keep the route.
require "action_controller"
require "standard_circuit"

StandardCircuit.deprecator.warn(
  'require "standard_circuit/health_controller" is no longer needed: the engine ' \
  "autoloads StandardCircuit::HealthController. Remove the require and keep the " \
  '`get "/health", to: "standard_circuit/health#show"` route.'
)

# Booted Rails app (e.g. required from config/routes.rb): the engine's
# autoloader already has an autoload set for the constant, so there is nothing
# to do — loading the file here would race Zeitwerk for the same path.
# Otherwise (required from an initializer before autoloaders are set up, or
# outside Rails entirely) load it directly; Zeitwerk later sees the constant
# is defined and leaves it alone.
unless StandardCircuit.autoload?(:HealthController) || StandardCircuit.const_defined?(:HealthController, false)
  require_relative "../../app/controllers/standard_circuit/health_controller"
end
