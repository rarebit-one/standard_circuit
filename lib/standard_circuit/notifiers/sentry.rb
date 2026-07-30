module StandardCircuit
  module Notifiers
    # Subscribes to standard_circuit.circuit.opened and forwards a message to
    # Sentry. Other transitions are ignored — only RED matters for alerting.
    #
    # Two reporting shapes:
    #
    # * **Flat** (default, and the only 0.2.x behaviour): every circuit reports
    #   at `:warning` with the circuit's colors and error in `extra`. No tags,
    #   no fingerprint.
    # * **Criticality-aware** (opt in via `config.sentry_criticality_levels`):
    #   the level is chosen from the circuit's registered criticality, and the
    #   report gains `circuit` / `circuit_criticality` tags plus a stable
    #   `["circuit-open", circuit]` fingerprint so Sentry alert rules can route
    #   and group by circuit.
    #
    # Flat stays the default deliberately. Both the level and the fingerprint
    # feed Sentry's alerting and grouping, so a gem bump must not silently
    # re-page or re-group a host app's existing issues — see CHANGELOG.
    class Sentry
      OPENED_EVENT = "standard_circuit.circuit.opened".freeze

      # Level used in flat mode, and the fallback for an unrecognised
      # criticality in criticality-aware mode.
      DEFAULT_LEVEL = :warning

      # The recommended criticality -> Sentry level mapping, used when
      # `config.sentry_criticality_levels = true`. :critical is loud enough to
      # page; :optional stays informational so a flapping nice-to-have
      # upstream doesn't cry wolf.
      DEFAULT_LEVELS = {
        critical: :error,
        standard: :warning,
        optional: :info
      }.freeze

      # @param levels [Hash{Symbol=>Symbol}, nil] criticality -> level map.
      #   nil (the default) selects flat :warning reporting.
      def initialize(levels: nil)
        @levels = levels
      end

      def call(event_name, payload)
        return unless event_name == OPENED_EVENT
        return unless defined?(::Sentry) && ::Sentry.respond_to?(:capture_message)

        @levels ? capture_criticality_aware(payload) : capture_flat(payload)
      end

      private

      def capture_flat(payload)
        message = "Circuit breaker opened: #{payload[:circuit]}"
        ::Sentry.capture_message(
          message,
          level: DEFAULT_LEVEL,
          extra: base_extra(payload)
        )
        message
      end

      def capture_criticality_aware(payload)
        circuit = payload[:circuit].to_s
        criticality = (payload[:criticality] || Config::DEFAULT_CRITICALITY).to_sym
        message = "Circuit breaker opened: #{circuit} (#{criticality})"

        ::Sentry.capture_message(
          message,
          level: @levels.fetch(criticality, DEFAULT_LEVEL),
          tags: { circuit: circuit, circuit_criticality: criticality.to_s },
          fingerprint: [ "circuit-open", circuit ],
          extra: base_extra(payload).merge(circuit: circuit, criticality: criticality)
        )
        message
      end

      def base_extra(payload)
        {
          circuit: payload[:circuit],
          from_color: payload[:from_color],
          to_color: payload[:to_color],
          error_class: payload[:error_class],
          error_message: payload[:error_message]
        }.compact
      end
    end
  end
end
