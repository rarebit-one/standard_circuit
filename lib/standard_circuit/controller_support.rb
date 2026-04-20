require "active_support/concern"
require "action_controller"

module StandardCircuit
  module ControllerSupport
    extend ActiveSupport::Concern

    included do
      rescue_from Stoplight::Error::RedLight do |error|
        handle_circuit_open(error)
      end

      class_attribute :_circuit_open_fallback, instance_accessor: false, default: nil
    end

    class_methods do
      def circuit_open_fallback(status: :service_unavailable, html: nil, json: nil, stream: nil)
        self._circuit_open_fallback = {
          status: status,
          html: html,
          json: json,
          stream: stream
        }
      end
    end

    private

    def handle_circuit_open(error)
      fallback = self.class._circuit_open_fallback || {}
      emit_circuit_open_metric(error)

      return instance_exec(&fallback[:json]) if request.format.json? && fallback[:json]
      return instance_exec(response, &fallback[:stream]) if streaming_controller? && fallback[:stream]
      return instance_exec(&fallback[:html]) if fallback[:html]

      head(fallback[:status] || :service_unavailable)
    end

    def streaming_controller?
      defined?(::ActionController::Live) && self.class.include?(::ActionController::Live)
    end

    def emit_circuit_open_metric(error)
      return unless defined?(::Sentry::Metrics)

      prefix = StandardCircuit.config.metric_prefix
      ::Sentry::Metrics.count(
        "#{prefix}.request",
        value: 1,
        attributes: { service: error.light_name, status: "circuit_open" }
      )
    end
  end
end
