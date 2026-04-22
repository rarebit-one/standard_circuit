require "standard_circuit"

# Full StandardCircuit state reset between examples.
#
# - Clears the light cache so rebuilt lights pick up fresh config if a spec
#   mutates it.
# - Clears forced states (force_open / force_closed).
# - Swaps a fresh Stoplight::DataStore::Memory into the Config when the
#   current store is already Memory, so failure counters from one spec don't
#   leak into the next. Redis stores are left alone.
#
# This is intentionally `before(:each)` rather than `after(:each)` so the
# setup happens even when a previous example aborted in an after hook.
RSpec.configure do |config|
  config.before(:each) do
    StandardCircuit.reset!
  end
end
