require "standard_circuit"

# Full StandardCircuit state reset between examples.
#
# - Clears the light cache so rebuilt lights pick up fresh config if a spec
#   mutates it.
# - Clears forced states (force_open / force_closed).
# - Tears down all event subscribers so a spec that subscribes manually doesn't
#   leak listeners into the next example. The internal Logger/Sentry/Metrics
#   subscribers are re-registered if a spec calls `StandardCircuit.configure`
#   or `StandardCircuit.subscribers.setup!`.
# - Swaps a fresh Stoplight::DataStore::Memory into the Config when the
#   current store is already Memory, so failure counters from one spec don't
#   leak into the next. Redis stores are left alone.
#
# Circuit registrations are intentionally NOT cleared. Host apps usually
# define circuits once in a `config/initializers/standard_circuit.rb`
# initializer; clearing the registry between examples would force every spec
# to re-`configure`. Specs that register circuits in `before(:each)` are
# unaffected by leftover registrations from prior examples (the new register
# call wins). If you do need a clean registry, call
# `StandardCircuit.config.reset_registry!` explicitly in your own hook.
#
# This is intentionally `before(:each)` rather than `after(:each)` so the
# setup happens even when a previous example aborted in an after hook.
RSpec.configure do |config|
  config.before(:each) do
    StandardCircuit.reset!
    StandardCircuit.subscribers.teardown!
  end
end
