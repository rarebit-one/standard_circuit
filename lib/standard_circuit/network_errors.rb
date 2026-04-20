require "net/http"
require "openssl"
require "socket"

module StandardCircuit
  module NetworkErrors
    DEFAULTS = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EHOSTUNREACH,
      Errno::ETIMEDOUT,
      SocketError,
      OpenSSL::SSL::SSLError
    ].freeze

    def self.defaults
      DEFAULTS.dup
    end
  end
end
