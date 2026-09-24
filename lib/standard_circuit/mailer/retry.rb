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
    # DOMAINS only — never addresses or subjects. Then the CircuitOpenError is
    # re-raised, so the job FAILS (dead letter) rather than completing with
    # the email dropped (0.4.2; 0.4.0/0.4.1 swallowed it).
    module Retry
      EXHAUSTED_EVENT = "standard_circuit.mailer.retries_exhausted".freeze
      EXHAUSTED_MESSAGE = "Email delivery failed: mail circuit breaker retries exhausted".freeze
      FINGERPRINT = "standard_circuit-mailer-retries-exhausted".freeze

      # Prepended onto ActiveJob::Base's singleton class only when the
      # :active_job hook fired mid-way through MailDeliveryJob's own
      # definition. MailDeliveryJob is complete by the time anything
      # subclasses it, and installing on it before the subclass body runs keeps
      # the handler's precedence the same as for any other load order.
      module InstallBeforeSubclassing
        def inherited(subclass)
          StandardCircuit::Mailer::Retry.install_configured if name == "ActionMailer::MailDeliveryJob"
          super
        end
      end

      class << self
        # Defers installation until MailDeliveryJob can be referenced safely,
        # so enabling this from an early initializer doesn't force ActiveJob
        # or ActionMailer to load before their own configuration is applied.
        # The hooks read the live config when they run; they are registered
        # once.
        #
        # `ActionMailer::MailDeliveryJob` can't simply be referenced from an
        # `on_load(:active_job)` hook: when `class MailDeliveryJob <
        # ActiveJob::Base` is itself what loads ActiveJob::Base (a mailer or
        # `deliver_later` touched first in a lazily-loaded process), the hook
        # fires while that class is still being autoloaded and the reference
        # raises NameError. So each trigger checks first, and together they
        # cover every load order:
        #
        # * :active_job — installs straight away when ActiveJob::Base loads
        #   ahead of MailDeliveryJob (eager load, or any ApplicationJob first).
        # * :action_mailer — ActionMailer::Base references MailDeliveryJob, so
        #   by the time this runs the class is complete. Every delivery goes
        #   through a mailer class, so this runs before the first delivery can
        #   raise, including in a worker that deserialized the job first
        #   (rescue handlers are read when an error is rescued, not at enqueue).
        # * the first subclass of MailDeliveryJob — covers a custom
        #   `delivery_job` loaded ahead of any mailer, which would otherwise
        #   take a copy of the parent's rescue handlers without this one.
        def install_on_load
          return if @on_load_registered

          @on_load_registered = true
          ::ActiveSupport.on_load(:active_job) do
            if StandardCircuit::Mailer::Retry.mail_delivery_job_referenceable?
              StandardCircuit::Mailer::Retry.install_configured
            else
              singleton_class.prepend(StandardCircuit::Mailer::Retry::InstallBeforeSubclassing)
            end
          end
          ::ActiveSupport.on_load(:action_mailer) { StandardCircuit::Mailer::Retry.install_configured }
        end

        # Installs on ActionMailer::MailDeliveryJob with the configured options
        # when mailer_retry is on and the class is safe to reference. Returns
        # true when the handler is in place afterwards.
        def install_configured
          options = StandardCircuit.config.mailer_retry
          return false unless options && mail_delivery_job_referenceable?

          install(::ActionMailer::MailDeliveryJob, options)
          true
        end

        # False only while MailDeliveryJob is mid-autoload on this thread (see
        # install_on_load): Ruby reports an in-progress autoload as undefined.
        # When the autoload is merely pending, referencing it loads it normally.
        def mail_delivery_job_referenceable?
          defined?(::ActionMailer) && ::ActionMailer.const_defined?(:MailDeliveryJob, false)
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
            StandardCircuit::Mailer::Retry.exhausted!(job, error)
          end
          true
        end

        # Runs when the last attempt still hits an open circuit. Reports first
        # (log, fingerprinted Sentry event, retries_exhausted event), then
        # RE-RAISES so the job fails. ActiveJob's retry_on swallows the error
        # when given a block unless the block raises, and a swallowed error
        # means the job "succeeds" and the email is silently dropped. Raising
        # lands it in the queue backend's failed executions (Solid Queue's
        # dead letter), where it can be inspected and retried.
        #
        # A report that raises must not turn into a dropped email, so it is
        # rescued and logged; the original error is raised regardless.
        #
        # @api private
        def exhausted!(job, error)
          begin
            report_exhausted(job, error)
          rescue StandardError => report_error
            logger&.error("[standard_circuit] failed to report mail retry exhaustion: #{report_error.class}: #{report_error.message}")
          end
          raise error
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
