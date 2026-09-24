module StandardCircuit
  # Named circuit registrations for integrations whose settings were being
  # copy-pasted, line for line, across host apps. Use via
  # `Config#register_preset`:
  #
  #   StandardCircuit.configure do |c|
  #     c.register_preset(:postmark)                   # named circuit :postmark
  #     c.register_preset(:s3)                         # prefix "s3" (s3_<bucket>)
  #     c.register_preset(:postmark, criticality: :critical) # override any option
  #   end
  #
  # A preset only fills in defaults — every `register` option passed alongside
  # it wins. Each preset also requires its SDK before computing the error
  # lists, so the taxonomy can't silently degrade to network errors only when
  # the SDK is declared `require: false` and hasn't been loaded yet at
  # configure time.
  module Presets
    Preset = Struct.new(:scope, :sdk_require, :sdk_constant, :options, keyword_init: true)

    REGISTRY = {
      # Postmark API delivery behind the `:standard_circuit` mailer delivery
      # method. 60s cool-off pairs with `mailer_retry`'s 90s default wait, so a
      # retried delivery lands after the breaker has had a chance to half-open.
      # :standard — an email outage is user-visible but non-blocking.
      postmark: Preset.new(
        scope: :name,
        sdk_require: "postmark",
        sdk_constant: "Postmark::HttpServerError",
        options: -> {
          {
            threshold: 3,
            cool_off_time: 60,
            criticality: :standard,
            tracked_errors: ErrorTaxonomies::Postmark.tracked,
            skipped_errors: AdapterErrors::Postmark.caller_errors
          }
        }
      ),
      # Per-bucket S3 circuits for `service: StandardCircuitS3` in storage.yml,
      # which keys its circuit as `s3_<bucket>` — hence a prefix registration.
      # `skipped_errors` is left to `ErrorTaxonomies.default_skipped_for`, which
      # skips AccessDenied / NoSuchKey.
      s3: Preset.new(
        scope: :prefix,
        sdk_require: "aws-sdk-s3",
        sdk_constant: "Aws::S3::Errors::NoSuchKey",
        options: -> {
          {
            threshold: 3,
            cool_off_time: 30,
            criticality: :standard,
            tracked_errors: ErrorTaxonomies::Aws.tracked
          }
        }
      )
    }.freeze

    class << self
      def names
        REGISTRY.keys
      end

      # Returns `[scope, options]` for +preset+ with +overrides+ merged on top.
      # Raises ArgumentError for an unknown preset or a missing SDK.
      def resolve(preset, **overrides)
        entry = REGISTRY.fetch(preset.to_sym) do
          raise ArgumentError, "unknown preset #{preset.inspect}; available: #{names.inspect}"
        end
        load_sdk!(preset, entry)
        [ entry.scope, entry.options.call.merge(overrides) ]
      end

      private

      def load_sdk!(preset, entry)
        return if Object.const_defined?(entry.sdk_constant)

        begin
          require entry.sdk_require
        rescue LoadError
          nil
        end
        return if Object.const_defined?(entry.sdk_constant)

        raise ArgumentError,
          "preset #{preset.inspect} needs the #{entry.sdk_require} gem (#{entry.sdk_constant} is not defined)"
      end
    end
  end
end
