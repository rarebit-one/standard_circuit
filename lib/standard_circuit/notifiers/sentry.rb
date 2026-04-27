module StandardCircuit
  module Notifiers
    # Subscribes to standard_circuit.circuit.opened and forwards a warning-level
    # message to Sentry. Other transitions are ignored — only RED matters for
    # alerting.
    class Sentry
      def call(event_name, payload)
        return unless event_name == "standard_circuit.circuit.opened"
        return unless defined?(::Sentry) && ::Sentry.respond_to?(:capture_message)

        message = "Circuit breaker opened: #{payload[:circuit]}"
        ::Sentry.capture_message(
          message,
          level: :warning,
          extra: {
            circuit: payload[:circuit],
            from_color: payload[:from_color],
            to_color: payload[:to_color],
            error_class: payload[:error_class],
            error_message: payload[:error_message]
          }.compact
        )
        message
      end
    end
  end
end
