require_relative "circuit_open_error"

module StandardCircuit
  module Mailer
    # Opt-in `retry_on CircuitOpenError` for ActionMailer's delivery job, so a
    # `deliver_later` that runs while the mail circuit is open is retried after
    # the breaker has had a chance to half-open, instead of failing once and
    # losing the email. Enabled with:
    #
    #   StandardCircuit.configure do |c|
    #     c.mailer_retry = true                           # 90s wait, 5 attempts, 15% jitter
    #     c.mailer_retry = { wait: 120, attempts: 8 }     # partial overrides
    #   end
    #
    # Keep `wait` longer than the mail circuit's `cool_off_time`, or each retry
    # lands on a still-open circuit.
    #
    # `ActionMailer::MailDeliveryJob` inherits from `ActiveJob::Base`, not the
    # host's ApplicationJob, which is why every app was patching it from an
    # initializer. Installation is idempotent — `configure` runs on every
    # `to_prepare` (so on every code reload in development), and `retry_on`
    # appends a rescue handler each time it's called — and it also stands down
    # when a handler for CircuitOpenError is already present, so a host that
    # still carries its own initializer doesn't end up with two.
    #
    # Subclasses of MailDeliveryJob (`self.delivery_job = MyJob`) inherit the
    # handler; a `retry_on CircuitOpenError` declared on the subclass wins.
    #
    # On exhaustion: one error log line, a Sentry `:error` event (when
    # `sentry_enabled` and Sentry is initialized), and a
    # `standard_circuit.mailer.retries_exhausted` event. PII: recipient
    # DOMAINS only — never addresses or subjects.
    module Retry
      EXHAUSTED_EVENT = "standard_circuit.mailer.retries_exhausted".freeze
      EXHAUSTED_MESSAGE = "Email delivery failed: mail circuit breaker retries exhausted".freeze
      FINGERPRINT = "standard_circuit-mailer-retries-exhausted".freeze

      class << self
        # Defers installation until ActiveJob::Base has loaded (immediately if
        # it already has), so enabling this from an early initializer doesn't
        # force ActiveJob to load before its own configuration is applied. The
        # hook reads the live config when it runs; it is registered once.
        def install_on_load
          return if @on_load_registered

          @on_load_registered = true
          ::ActiveSupport.on_load(:active_job) do
            options = StandardCircuit.config.mailer_retry
            StandardCircuit::Mailer::Retry.install(::ActionMailer::MailDeliveryJob, options) if options
          end
        end

        # Adds the retry_on to +job_class+ unless a CircuitOpenError handler is
        # already there. Returns true when it installed one.
        def install(job_class, options)
          return false if installed?(job_class)

          job_class.retry_on(
            CircuitOpenError,
            wait: options.fetch(:wait),
            attempts: options.fetch(:attempts),
            jitter: options.fetch(:jitter)
          ) do |job, error|
            StandardCircuit::Mailer::Retry.report_exhausted(job, error)
          end
          true
        end

        def installed?(job_class)
          job_class.rescue_handlers.any? { |(error_name, _handler)| error_name == CircuitOpenError.name }
        end

        def report_exhausted(job, error)
          mailer_class, mail_action = job.arguments
          details = {
            mailer_class: mailer_class,
            mail_action: mail_action,
            recipient_domains: recipient_domains(error.recipients),
            job_id: job.job_id,
            executions: job.executions
          }

          logger&.error("[standard_circuit] #{EXHAUSTED_MESSAGE} #{details.to_json}")
          capture_sentry(details)
          EventEmitter.emit(EXHAUSTED_EVENT, details)
          details
        end

        def recipient_domains(recipients)
          Array(recipients)
            .filter_map { |address| address.to_s.split("@", 2)[1]&.strip&.downcase }
            .reject(&:empty?)
            .uniq
        end

        # @api private — test isolation.
        def reset_on_load_registration!
          @on_load_registered = false
        end

        private

        def logger
          StandardCircuit.config.logger || (::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger))
        end

        def capture_sentry(details)
          return unless StandardCircuit.config.sentry_enabled
          return unless defined?(::Sentry) && ::Sentry.respond_to?(:initialized?) && ::Sentry.initialized?

          ::Sentry.capture_message(
            EXHAUSTED_MESSAGE,
            level: :error,
            fingerprint: [ FINGERPRINT, details[:mailer_class], details[:mail_action] ].map(&:to_s),
            extra: details
          )
        end
      end
    end
  end
end
