require "spec_helper"

RSpec.describe StandardCircuit::AdapterErrors::Smtp do
  describe ".server_errors" do
    it "lists transient/fatal server errors and dropped connections" do
      expect(described_class.server_errors).to eq(
        [ Net::SMTPServerBusy, Net::SMTPFatalError, Net::SMTPUnknownError, EOFError ]
      )
    end

    it "returns a fresh, mutable copy each call" do
      errors = described_class.server_errors
      expect(errors).not_to be_frozen

      errors << RuntimeError
      expect(described_class.server_errors).not_to include(RuntimeError)
    end
  end

  describe ".caller_errors" do
    it "lists syntax and authentication errors" do
      expect(described_class.caller_errors).to eq([ Net::SMTPSyntaxError, Net::SMTPAuthenticationError ])
    end

    it "returns a fresh, mutable copy each call" do
      errors = described_class.caller_errors
      expect(errors).not_to be_frozen

      errors << RuntimeError
      expect(described_class.caller_errors).not_to include(RuntimeError)
    end
  end

  it "keeps server and caller errors disjoint" do
    expect(described_class.server_errors & described_class.caller_errors).to be_empty
  end
end
