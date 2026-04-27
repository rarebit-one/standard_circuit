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
      # Rails iterates `rescue_handlers` from last-declared to first to find a
      # match, so a `rescue_from StandardError` declared *after* `include
      # StandardCircuit::ControllerSupport` shadows the gem's `RedLight` handler
      # registered in `included`. Re-appending the handler here makes the DSL
      # call effectively bump it to the end of the list — so as long as
      # `circuit_open_fallback` is the last thing in your controller (or at
      # least after any `rescue_from StandardError`-style catch-alls),
      # `Stoplight::Error::RedLight` keeps routing to `handle_circuit_open`.
      def circuit_open_fallback(status: :service_unavailable, html: nil, json: nil, stream: nil)
        self._circuit_open_fallback = {
          status: status,
          html: html,
          json: json,
          stream: stream
        }

        # Drop existing RedLight handlers on this class before re-appending so
        # repeated DSL calls (or sub-controllers calling the DSL after a base
        # controller did) don't accumulate duplicate entries in
        # `rescue_handlers`. Use the writer (not `reject!`) to avoid mutating
        # the array a parent class might still share via `class_attribute`.
        # Each entry's first element is a class-name string
        # ("Stoplight::Error::RedLight"), not the constant itself.
        self.rescue_handlers = rescue_handlers.reject { |handler| handler.first == "Stoplight::Error::RedLight" }

        rescue_from Stoplight::Error::RedLight do |error|
          handle_circuit_open(error)
        end
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
      prefix = StandardCircuit.config.metric_prefix
      ::Sentry::Metrics.count(
        "#{prefix}.request",
        value: 1,
        attributes: { service: error.light_name, status: "circuit_open" }
      )
    end
  end
end
