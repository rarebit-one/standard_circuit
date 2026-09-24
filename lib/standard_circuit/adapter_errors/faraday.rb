module StandardCircuit
  module AdapterErrors
    module Faraday
      class << self
        def server_errors
          return [] unless defined?(::Faraday::Error)

          errors = [ ::Faraday::TimeoutError, ::Faraday::ConnectionFailed ]
          errors << ::Faraday::ServerError if defined?(::Faraday::ServerError)
          errors.select { |klass| klass.is_a?(Class) }
        end

        # @deprecated Removed in 0.5. Faraday::ClientError (4xx) is not in
        # +server_errors+, so it never counts toward a Faraday circuit —
        # listing it in +skipped_errors+ is a no-op. Unused by every consumer.
        def caller_errors
          StandardCircuit.deprecator.warn(
            "StandardCircuit::AdapterErrors::Faraday.caller_errors is deprecated and will be removed in 0.5: " \
            "Faraday::ClientError is never tracked by ErrorTaxonomies::Faraday.tracked, so skipping it is a no-op. " \
            "Drop it from skipped_errors."
          )
          return [] unless defined?(::Faraday::ClientError)

          [ ::Faraday::ClientError ]
        end
      end
    end
  end
end
