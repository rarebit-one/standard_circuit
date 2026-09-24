module StandardCircuit
  module AdapterErrors
    # Postmark (the `postmark` gem, usually via `postmark-rails`).
    #
    # Guarded like the other adapters: every method returns `[]` when the
    # postmark gem isn't loaded, so this file is safe to require in apps that
    # don't send mail through Postmark.
    #
    # Postmark's error hierarchy is the reason `caller_errors` matters here:
    # `ApiInputError` (422 — invalid payload, inactive recipient, 429-style
    # throttling) and `InvalidApiKeyError` (401 — rotated / revoked token) both
    # subclass `HttpServerError`, and Stoplight matches tracked errors with
    # `is_a?`. Tracking `HttpServerError` without skipping them would let a
    # burst of bad payloads or a config bug trip the breaker.
    module Postmark
      class << self
        def server_errors
          return [] unless defined?(::Postmark::HttpServerError)

          [ ::Postmark::HttpServerError, ::Postmark::TimeoutError ]
        end

        def caller_errors
          return [] unless defined?(::Postmark::HttpServerError)

          [ ::Postmark::ApiInputError, ::Postmark::InvalidApiKeyError ]
        end
      end
    end
  end
end
