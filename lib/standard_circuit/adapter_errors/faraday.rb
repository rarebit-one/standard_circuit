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
      end
    end
  end
end
