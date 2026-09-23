require "spec_helper"

RSpec.describe StandardCircuit::NetworkErrors do
  describe ".defaults" do
    it "covers connection, timeout, DNS, and TLS failures" do
      expect(described_class.defaults).to contain_exactly(
        Net::OpenTimeout,
        Net::ReadTimeout,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::EHOSTUNREACH,
        Errno::ETIMEDOUT,
        SocketError,
        OpenSSL::SSL::SSLError
      )
    end

    it "contains only exception classes" do
      expect(described_class.defaults).to all(be_a(Class).and(be <= StandardError))
    end

    it "returns a fresh, mutable copy each call" do
      first = described_class.defaults
      expect(first).not_to be_frozen

      first << RuntimeError
      expect(described_class.defaults).not_to include(RuntimeError)
    end

    it "keeps DEFAULTS frozen" do
      expect(described_class::DEFAULTS).to be_frozen
    end
  end
end
