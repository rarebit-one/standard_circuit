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
# - Clears ALL of stoplight's in-process state (see RSpecSupport), so the
#   systems earlier examples left behind are freed.
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
module StandardCircuit
  module RSpecSupport
    class << self
      # What the helper does before each example.
      def reset_between_examples!
        StandardCircuit.reset!
        free_stoplight_state!
        StandardCircuit.subscribers.teardown!
      end

      # StandardCircuit.reset! has to start a new stoplight system generation
      # (stoplight never frees a system name), and stoplight keeps every
      # superseded system, with the lights built in it, for the life of the
      # process: some 20-35 KB per example that used a circuit. Stoplight's
      # own test reset, `Stoplight.__stoplight__reset!`, empties its registry,
      # which frees them and makes every name available again, so the runner
      # starts over at `standard_circuit` and generation numbers don't grow.
      #
      # That method is not stoplight's public API, so it is called only here,
      # in the test helper, never on the runtime path, and only while it
      # exists with the shape it has in stoplight 6.0.1 (no arguments). It
      # clears ALL stoplight state in the process, including circuits a host
      # registered with Stoplight directly. Without it the helper falls back
      # to plain generations: correct, just not freed, with one warning per
      # process.
      def free_stoplight_state!
        return warn_missing_reset_once unless private_reset_available?

        Stoplight.__stoplight__reset!
        Runner.restart_generations!
        StandardCircuit.runner.drop_system!
      end

      private

      def private_reset_available?
        Stoplight.respond_to?(:__stoplight__reset!) && Stoplight.method(:__stoplight__reset!).arity.zero?
      end

      def warn_missing_reset_once
        return if @warned_missing_reset

        @warned_missing_reset = true
        warn "[StandardCircuit] Stoplight.__stoplight__reset! is unavailable; superseded stoplight systems " \
             "are not freed between examples (each example that uses a circuit retains a little memory)."
      end
    end
  end
end

RSpec.configure do |config|
  config.before(:each) do
    StandardCircuit::RSpecSupport.reset_between_examples!
  end
end
