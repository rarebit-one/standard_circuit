module StandardCircuit
  module Mailer
    # Default error class raised by +StandardCircuit::Mailer::DeliveryMethod+
    # when the wrapped mailer circuit is open. Mailer jobs can rescue/retry on
    # this class to defer delivery until the upstream recovers.
    #
    # Constructor contract (matches DeliveryMethod#deliver!):
    #   new(recipients:, subject:)
    #
    # Consumers that want their own error class can still pass
    # +retry_error_class:+ to the delivery method settings; this class is the
    # default when none is provided.
    class CircuitOpenError < StandardError
      attr_reader :recipients, :subject

      def initialize(recipients:, subject:)
        @recipients = recipients
        @subject = subject
        super("Circuit breaker is open: to=#{recipients.inspect} subject=#{subject.inspect}")
      end
    end
  end
end
