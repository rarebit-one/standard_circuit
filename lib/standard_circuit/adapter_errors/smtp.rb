require "net/smtp"

module StandardCircuit
  module AdapterErrors
    module Smtp
      SERVER_ERRORS = [
        Net::SMTPServerBusy,
        Net::SMTPFatalError,
        Net::SMTPUnknownError,
        EOFError
      ].freeze

      CALLER_ERRORS = [
        Net::SMTPSyntaxError,
        Net::SMTPAuthenticationError
      ].freeze

      def self.server_errors
        SERVER_ERRORS.dup
      end

      def self.caller_errors
        CALLER_ERRORS.dup
      end
    end
  end
end
