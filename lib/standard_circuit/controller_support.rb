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
      #
      # `json:` and `html:` are run in the controller and may take the
      # Stoplight::Error::RedLight as an argument (0.8); zero-arity lambdas
      # still work. Every circuit-open response carries `Retry-After` when
      # the delay is known (see #set_circuit_retry_after).
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
      # No metric here: Runner already counted this rejection as
      # `<metric_prefix>.request{status: circuit_open}` before re-raising.
      fallback = self.class._circuit_open_fallback || {}
      set_circuit_retry_after(error)

      return call_circuit_open_fallback(fallback[:json], error) if request.format.json? && fallback[:json]
      return instance_exec(response, &fallback[:stream]) if streaming_controller? && fallback[:stream]
      return call_circuit_open_fallback(fallback[:json], error) if fallback[:json] && circuit_open_api_request?
      return call_circuit_open_fallback(fallback[:html], error) if fallback[:html]

      head(fallback[:status] || :service_unavailable)
    end

    # An API client gets the `json:` body even when it didn't ask for JSON
    # by name (0.8.1): every request to an ActionController::API controller,
    # and any request that doesn't accept HTML. `Accept: */*` and a missing
    # Accept header both accept HTML (Rails reads them as `*/*` and `html`),
    # so an ActionController::Base controller keeps answering them with
    # `html:`, as before.
    def circuit_open_api_request?
      return true if defined?(::ActionController::API) && self.class <= ::ActionController::API

      # A parsed `*/*` is a symbol-less Mime::Type, not Mime::ALL, and answers
      # html? false, so match the wildcard by its ref.
      request.formats.none? { |format| format.html? || format.ref == "*/*" }
    end

    # `json:` / `html:` lambdas may take the RedLight (to name the circuit, or
    # echo the retry delay); the zero-arity lambdas written before 0.8 still
    # work unchanged.
    def call_circuit_open_fallback(callable, error)
      callable.arity.zero? ? instance_exec(&callable) : instance_exec(error, &callable)
    end

    # Tell the client when to come back, in whole seconds: until the
    # breaker's recovery probe (the RedLight's `retry_after`), else the
    # circuit's cool-off (a breaker locked or forced open has no recovery
    # time), else not at all. Never less than 1, so a client honouring it
    # can't spin.
    def set_circuit_retry_after(error)
      seconds = circuit_retry_after_seconds(error)
      response.headers["Retry-After"] = seconds.to_s if seconds && response
    rescue StandardError
      nil # a header is not worth failing the fallback response over
    end

    def circuit_retry_after_seconds(error)
      retry_after = error.respond_to?(:retry_after) ? error.retry_after : nil
      seconds =
        if retry_after.respond_to?(:to_time)
          retry_after.to_time - Time.now
        elsif retry_after.is_a?(Numeric)
          retry_after
        else
          name = error.respond_to?(:light_name) ? error.light_name : nil
          name && StandardCircuit.config.spec_for(name)&.cool_off_time
        end
      seconds && [ seconds.ceil, 1 ].max
    end

    def streaming_controller?
      defined?(::ActionController::Live) && self.class.include?(::ActionController::Live)
    end
  end
end
