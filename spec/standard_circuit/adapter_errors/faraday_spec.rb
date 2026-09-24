require "spec_helper"
require "faraday"

RSpec.describe StandardCircuit::AdapterErrors::Faraday do
  describe ".server_errors" do
    it "lists timeout, connection-failed, and server (5xx) errors" do
      expect(described_class.server_errors).to eq(
        [ Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::ServerError ]
      )
    end

    it "returns [] when faraday isn't loaded" do
      hide_const("Faraday")
      expect(described_class.server_errors).to eq([])
    end
  end

  it "no longer defines .caller_errors (removed in 0.5; Faraday::ClientError is never tracked)" do
    expect(described_class).not_to respond_to(:caller_errors)
  end

  it "never tracks client (4xx) errors" do
    described_class.server_errors.each do |server_error|
      expect(server_error).not_to be <= Faraday::ClientError
    end
  end
end
