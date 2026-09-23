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

  describe ".caller_errors" do
    it "lists the ClientError (4xx) base class" do
      expect(described_class.caller_errors).to eq([ Faraday::ClientError ])
    end

    it "covers specific 4xx subclasses" do
      expect(described_class.caller_errors.first).to be > Faraday::ResourceNotFound
    end

    it "returns [] when faraday isn't loaded" do
      hide_const("Faraday")
      expect(described_class.caller_errors).to eq([])
    end
  end

  it "keeps server and caller errors from overlapping" do
    described_class.server_errors.each do |server_error|
      expect(server_error).not_to be <= Faraday::ClientError
    end
  end
end
