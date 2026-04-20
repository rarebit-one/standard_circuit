module StandardCircuit
  module AdapterErrors
    module Stripe
      class << self
        def server_errors
          return [] unless defined?(::Stripe::StripeError)

          [
            ::Stripe::APIConnectionError,
            ::Stripe::RateLimitError,
            ::Stripe::APIError
          ]
        end

        def caller_errors
          return [] unless defined?(::Stripe::StripeError)

          [
            ::Stripe::InvalidRequestError,
            ::Stripe::CardError,
            ::Stripe::AuthenticationError
          ]
        end
      end
    end
  end
end
