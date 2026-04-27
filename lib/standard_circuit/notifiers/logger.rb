require "logger"

module StandardCircuit
  module Notifiers
    # Subscribes to standard_circuit.circuit.* events and writes a human-readable
    # log line for each transition. Always-on by default; pass a custom logger
    # via `StandardCircuit.config.logger=`.
    class Logger
      TRANSITION_EVENTS = %w[
        standard_circuit.circuit.opened
        standard_circuit.circuit.closed
        standard_circuit.circuit.degraded
      ].freeze

      def initialize(logger = nil)
        @logger = logger || ::Logger.new($stdout)
      end

      def call(event_name, payload)
        return unless TRANSITION_EVENTS.include?(event_name)

        message = build_message(event_name, payload)
        level = event_name == "standard_circuit.circuit.opened" ? :warn : :info
        @logger.public_send(level, message)
        message
      end

      private

      def build_message(event_name, payload)
        words = [
          "Stoplight",
          payload[:circuit],
          "switched from",
          payload[:from_color],
          "to",
          payload[:to_color]
        ]
        if payload[:error_class]
          words += [ "because", payload[:error_class], payload[:error_message] ]
        end
        words.join(" ")
      end
    end
  end
end
