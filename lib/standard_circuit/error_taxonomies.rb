module StandardCircuit
  # Pre-combined `tracked_errors` sets per adapter — saves consumers from
  # typing the same `NetworkErrors.defaults + AdapterErrors::X.server_errors`
  # line for every circuit they register, and gives a single place to evolve
  # what counts as a "server-side outage" for each integration.
  #
  # Each adapter's `tracked` returns a fresh array, so callers can safely
  # `+` additional app-specific error classes without mutating shared state.
  #
  # Example:
  #   c.register(:stripe,
  #     tracked_errors: StandardCircuit::ErrorTaxonomies::Stripe.tracked,
  #     skipped_errors: StandardCircuit::AdapterErrors::Stripe.caller_errors)
  #
  # Adapter-specific `caller_errors` (validation/auth/etc.) stay on
  # `AdapterErrors::*` because the right `skipped_errors` set is usually
  # app-specific and a shared taxonomy would over-skip.
  module ErrorTaxonomies
    module Stripe
      def self.tracked
        NetworkErrors.defaults + AdapterErrors::Stripe.server_errors
      end
    end

    module Smtp
      def self.tracked
        NetworkErrors.defaults + AdapterErrors::Smtp.server_errors
      end
    end

    module Aws
      def self.tracked
        NetworkErrors.defaults + AdapterErrors::Aws.server_errors
      end
    end

    module Faraday
      def self.tracked
        NetworkErrors.defaults + AdapterErrors::Faraday.server_errors
      end
    end
  end
end
