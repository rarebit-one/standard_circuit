module StandardCircuit
  module AdapterErrors
    module Aws
      class << self
        def server_errors
          errors = []
          errors << ::Seahorse::Client::NetworkingError if defined?(::Seahorse::Client::NetworkingError)
          errors << ::Aws::Errors::ServiceError if defined?(::Aws::Errors::ServiceError)
          errors
        end

        def caller_errors
          return [] unless defined?(::Aws::S3::Errors::NoSuchKey)

          [
            ::Aws::S3::Errors::NoSuchKey,
            ::Aws::S3::Errors::AccessDenied
          ].select { |klass| klass.is_a?(Class) }
        end
      end
    end
  end
end
