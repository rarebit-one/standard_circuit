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
    # Default `skipped_errors` for a circuit registered without an explicit
    # `skipped_errors:`. Most adapters default to `[]`, but AWS can't: its 5xx
    # errors are dynamically generated `Aws::Errors::ServiceError` subclasses
    # (e.g. `Aws::S3::Errors::ServiceUnavailable`), so `Aws.tracked` has to
    # track `ServiceError` itself — which is also the superclass of caller
    # errors like `AccessDenied` and `NoSuchKey`. Without a skip list, a burst
    # of missing-key lookups or permission errors would trip the S3 breaker.
    #
    # Returns the AWS caller errors that some entry of +tracked+ covers (is the
    # same class or an ancestor of), or `[]` when none are covered. Returns a
    # fresh array each call.
    def self.default_skipped_for(tracked)
      trackable = Array(tracked).grep(Module)
      AdapterErrors::Aws.caller_errors.select do |caller_error|
        trackable.any? { |klass| caller_error <= klass }
      end
    end

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
