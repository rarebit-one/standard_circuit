module StandardCircuit
  module Notifiers
    # Subscribes to all standard_circuit.circuit.{opened,closed,degraded} events
    # and emits a Sentry::Metrics counter with the canonical state name.
    class Metrics
      STATE_FOR_EVENT = {
        "standard_circuit.circuit.opened"   => "opened",
        "standard_circuit.circuit.closed"   => "closed",
        "standard_circuit.circuit.degraded" => "half_open"
      }.freeze

      def initialize(metric_prefix: "external")
        @metric_prefix = metric_prefix
      end

      def call(event_name, payload)
        state = STATE_FOR_EVENT[event_name]
        return unless state

        ::Sentry::Metrics.count(
          "#{@metric_prefix}.circuit_breaker",
          value: 1,
          attributes: { service: payload[:circuit], state: state }
        )
      end
    end
  end
end
